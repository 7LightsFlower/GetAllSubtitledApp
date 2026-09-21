# youtube_downloader.py
from flask import Flask, request, jsonify, send_file
import yt_dlp
import os
import tempfile

app = Flask(__name__)

@app.route('/api/youtube-download', methods=['POST'])
def download_youtube():
    try:
        data = request.get_json()
        url = data.get('url')
        
        if not url:
            return jsonify({'error': 'URL is required'}), 400
        
        # Extract video ID
        video_id = extract_video_id(url)
        if not video_id:
            return jsonify({'error': 'Invalid YouTube URL'}), 400
        
        # Download video using yt-dlp
        ydl_opts = {
            'format': 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
            'quiet': True,
            'no_warnings': True,
            'outtmpl': '%(title)s.%(ext)s',
        }
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            
            # Get the video URL
            video_url = info.get('url')
            if not video_url:
                # Try to get from formats
                formats = info.get('formats', [])
                for fmt in formats:
                    if fmt.get('ext') == 'mp4' and fmt.get('vcodec') != 'none':
                        video_url = fmt.get('url')
                        break
            
            if not video_url:
                return jsonify({'error': 'Could not find video URL'}), 400
            
            return jsonify({
                'success': True,
                'url': video_url,
                'title': info.get('title', 'video'),
                'duration': info.get('duration', 0),
                'thumbnail': info.get('thumbnail', ''),
                'format': 'mp4'
            })
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500

def extract_video_id(url):
    import re
    patterns = [
        r'youtube\.com/watch\?v=([^&]+)',
        r'youtu\.be/([^?]+)',
        r'youtube\.com/shorts/([^?]+)',
        r'youtube\.com/embed/([^?]+)',
        r'youtube\.com/v/([^?]+)',
    ]
    for pattern in patterns:
        match = re.search(pattern, url)
        if match:
            return match.group(1)
    return None

if __name__ == '__main__':
    app.run(port=5000)