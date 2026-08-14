#!/usr/bin/env python3
import os
import requests
from flask import Flask, request, render_template_string, jsonify, make_response
from flask_cors import CORS
import logging

logging.basicConfig(level=logging.INFO)

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 1024 * 1024 * 1024  # 1 GB

CORS(app, origins=["http://localhost:8080", "http://127.0.0.1:8080"])

TARGET_URL = "https://lt2srv-sscherrer.isl.iar.kit.edu/upload_lecture"

# HTML page (kept for manual browser testing) – we can keep it as is.
HTML_PAGE = """<!DOCTYPE html>
... (your existing HTML, same as before) ...
"""

@app.route('/', methods=['GET'])
def index():
    return HTML_PAGE

@app.route('/upload', methods=['POST'])
def upload():
    token = request.form.get('token', '')
    if not token:
        return "Missing token", 400

    # Build data dict (all fields except token, handling multiple values)
    data = {}
    for key in request.form.keys():
        if key == 'token':
            continue
        values = request.form.getlist(key)
        if len(values) == 1:
            data[key] = values[0]
        else:
            data[key] = values

    # Build files dict
    files = {}
    if 'videofile' in request.files:
        file_obj = request.files['videofile']
        if file_obj.filename:
            files['videofile'] = (file_obj.filename, file_obj.stream, file_obj.content_type)

    headers = {
        'X-Forward-Auth': token,
        'User-Agent': 'Mozilla/5.0 (compatible; LT-Uploader/1.0)',
        'Accept': 'application/json'   # ask for JSON if possible
    }
    cookies = {'_forward_auth': token}

    try:
        # Follow redirects so we can inspect the final URL
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

        # 1. If the LT server returned JSON with a session_id, forward it
        content_type = resp.headers.get('Content-Type', '')
        if 'application/json' in content_type:
            try:
                json_data = resp.json()
                if 'session_id' in json_data:
                    return jsonify(json_data), resp.status_code
            except Exception:
                pass

        # 2. If the final URL contains '/session/', extract the ID
        final_url = resp.url
        if '/session/' in final_url:
            session_id = final_url.split('/session/')[-1].split('/')[0]
            return jsonify({'session_id': session_id}), 200

        # 3. Otherwise, return the raw response (could be HTML success page)
        return resp.text, resp.status_code, {'Content-Type': resp.headers.get('Content-Type', 'text/plain')}

    except requests.exceptions.ConnectionError as e:
        app.logger.error(f"Connection error: {e}")
        return f"Connection error: {str(e)}", 500
    except Exception as e:
        app.logger.error(f"Error: {e}")
        return f"Proxy error: {str(e)}", 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8081, debug=True)
    