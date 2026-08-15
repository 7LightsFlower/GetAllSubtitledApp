#!/usr/bin/env python3
import os
import base64
import requests
from flask import Flask, request, jsonify, make_response
from flask_cors import CORS
import logging

logging.basicConfig(level=logging.INFO)

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 1024 * 1024 * 1024  # 1 GB

# Enable CORS for Flutter web
CORS(app, origins=["http://localhost:8080", "http://127.0.0.1:8080"])

TARGET_URL = "https://lt2srv-sscherrer.isl.iar.kit.edu/upload_lecture"
BASE_URL = "https://lt2srv-sscherrer.isl.iar.kit.edu"

# --- Keep your beautiful HTML form at '/' (unchanged) ---
HTML_PAGE = """... your existing HTML page ..."""

@app.route('/', methods=['GET'])
def index():
    return HTML_PAGE

@app.route('/upload', methods=['POST'])
def upload():
    token = request.form.get('token', '')
    if not token:
        return "Missing token", 400

    # Build data dict (same as before)
    data = {}
    for key in request.form.keys():
        if key == 'token':
            continue
        values = request.form.getlist(key)
        data[key] = values[0] if len(values) == 1 else values

    session_name = data.get('name', '').strip()
    user_email = data.get('path', '/home/admin@example.com').strip('/').split('/')[-1]

    files = {}
    if 'videofile' in request.files:
        file_obj = request.files['videofile']
        if file_obj.filename:
            files['videofile'] = (file_obj.filename, file_obj.stream, file_obj.content_type)

    headers = {
        'X-Forward-Auth': token,
        'User-Agent': 'Mozilla/5.0 (compatible; LT-Uploader/1.0)'
    }
    cookies = {'_forward_auth': token}

    try:
        # Follow redirects to get the final URL
        resp = requests.post(
            TARGET_URL,
            data=data,
            files=files,
            headers=headers,
            cookies=cookies,
            timeout=(10, 1800),
            verify=False,
            allow_redirects=True
        )

        final_url = resp.url
        session_id = None

        # Extract session ID from redirect URL
        if '/archivesession/' in final_url:
            session_id = final_url.split('/archivesession/')[-1].split('/')[0]
        elif '/session/' in final_url:
            session_id = final_url.split('/session/')[-1].split('/')[0]

        # If not found, build it from the form data (fallback)
        if not session_id and session_name:
            path = f"/home/{user_email}/{session_name}"
            session_id = base64.b64encode(path.encode()).decode()

        # Get the LT server's original response
        content = resp.text
        content_type = resp.headers.get('Content-Type', 'text/html')

        # If the response is HTML, inject the session link before </body>
        if 'text/html' in content_type and session_id:
            link = f"{BASE_URL}/archivesession/{session_id}"
            inject = f"""
<div style="padding: 1rem; margin: 1rem; background: #eaf0f8; border-radius: 8px; text-align: center; border: 1px solid #b0c6dd;">
    <strong>📎 Session link:</strong><br>
    <a href="{link}" target="_blank" style="color: #1a4c8a; word-break: break-all;">{link}</a>
</div>
"""
            # Insert before </body>
            content = content.replace('</body>', inject + '</body>')

        # Return the (possibly modified) response with the original status and content type
        return content, resp.status_code, {'Content-Type': content_type}

    except Exception as e:
        app.logger.error(f"Error: {e}")
        return f"Proxy error: {str(e)}", 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8081, debug=True)
    