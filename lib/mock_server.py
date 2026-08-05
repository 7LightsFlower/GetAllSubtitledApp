from flask import Flask, request, jsonify
from flask_cors import CORS
import uuid
import datetime

app = Flask(__name__)
CORS(app)

users = {}
videos = []
chunk_storage = {}

# Helper to produce clean UTC datetime string (e.g., "2026-08-05T13:13:35.197Z")
def utc_now_iso():
    return datetime.datetime.now(datetime.UTC).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

# Dummy project
dummy_project = {
    'key': 'dummy-key-123',
    'name': 'Sample Video',
    'file_name': 'sample.mp4',
    'uploaded': utc_now_iso(),
    'last_opened': None,
    'duration': 60.0,
    'fps': 30.0,
    'file_size': 10485760,
    'segment_count': 5,
    'languages': ['en', 'de'],
    'thumbnail_url': None,
    'segmentation_done': True,
    'segmentation_progress': 100,
}
videos.append(dummy_project)

@app.route('/register', methods=['POST'])
def register():
    email = request.form.get('email')
    password = request.form.get('password')
    name = request.form.get('name', '')
    if not email or not password:
        return jsonify({'message': 'Email and password required'}), 400
    if email in users:
        return jsonify({'message': 'User already exists'}), 400
    users[email] = {'name': name, 'password': password}
    token = str(uuid.uuid4())
    return jsonify({'token': token, 'message': 'User registered successfully'}), 201

@app.route('/login', methods=['POST'])
def login():
    email = request.form.get('email')
    password = request.form.get('password')
    if not email or not password:
        return jsonify({'message': 'Email and password required'}), 400
    user = users.get(email)
    if not user or user['password'] != password:
        return jsonify({'message': 'Invalid credentials'}), 401
    token = str(uuid.uuid4())
    return jsonify({'token': token, 'message': 'Login successful'}), 200

@app.route('/videos', methods=['GET'])
def get_videos():
    storage_used_gb = sum(v.get('file_size', 0) for v in videos) / (1024.0 ** 3)
    print(f"📨 GET /videos: returning {len(videos)} projects")
    return jsonify({
        'projects': videos,
        'storage_used_gb': round(storage_used_gb, 2),
        'storage_limit_gb': 50.0
    }), 200

@app.route('/video_detail/<video_key>', methods=['GET'])
def video_detail(video_key):
    for project in videos:
        if project['key'] == video_key:
            detail = project.copy()
            # Ensure segments list exists (even empty)
            if 'segments' not in detail:
                detail['segments'] = []
            # Add optional fields that the Flutter app expects
            detail['video_url'] = None
            return jsonify(detail), 200
    return jsonify({'error': 'Video not found'}), 404

@app.route('/upload-chunk', methods=['POST'])
def upload_chunk():
    file = request.files.get('file')
    filename = request.form.get('filename')
    chunk_index = int(request.form.get('chunk_index', 0))
    total_chunks = int(request.form.get('total_chunks', 1))
    if not file or not filename:
        return jsonify({'message': 'Missing file or filename'}), 400
    if filename not in chunk_storage:
        chunk_storage[filename] = [None] * total_chunks
    bytes_data = file.read()
    chunk_storage[filename][chunk_index] = bytes_data
    print(f"📤 Uploaded chunk {chunk_index+1}/{total_chunks} for {filename}")
    return jsonify({'message': 'Chunk uploaded'}), 200

@app.route('/finish-upload', methods=['POST'])
def finish_upload():
    data = request.get_json()
    filename = data.get('filename')
    auto_segmentation = data.get('auto_segmentation', False)
    if not filename:
        return jsonify({'message': 'Missing filename'}), 400
    chunks = chunk_storage.get(filename)
    if not chunks or any(chunk is None for chunk in chunks):
        return jsonify({'message': 'Incomplete upload'}), 400
    combined = b''.join(chunks)
    file_size = len(combined)
    project = {
        'key': str(uuid.uuid4()),
        'name': filename.rsplit('.', 1)[0] if '.' in filename else filename,
        'file_name': filename,
        'uploaded': utc_now_iso(),
        'last_opened': None,
        'duration': 120.0,
        'fps': 30.0,
        'file_size': file_size,
        'segment_count': 0,
        'languages': ['en'],
        'thumbnail_url': None,
        'segmentation_done': auto_segmentation,
        'segmentation_progress': 100 if auto_segmentation else 0,
    }
    videos.append(project)
    print(f"✅ Added project: {project['name']} with key {project['key']}")
    print(f"📋 Total videos now: {len(videos)}")
    del chunk_storage[filename]
    return jsonify({'message': 'Upload finished', 'project': project}), 200

@app.route('/debug-videos', methods=['GET'])
def debug_videos():
    return jsonify({'count': len(videos), 'projects': videos}), 200

@app.route('/clear-videos', methods=['POST'])
def clear_videos():
    global videos
    videos = [dummy_project]  # keep dummy
    chunk_storage.clear()
    return jsonify({'message': 'Cleared'}), 200

if __name__ == '__main__':
    app.run(port=5000, debug=True)
               