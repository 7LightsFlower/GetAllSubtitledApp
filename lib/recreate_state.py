#!/usr/bin/env python3
"""Recreate server state from existing video files."""

import os
import pickle
import datetime
import uuid
import subprocess
import json

UPLOAD_FOLDER = os.path.join(os.path.dirname(__file__), "uploads")
STATE_FILE = os.path.join(os.path.dirname(__file__), "server_state.pkl")

def utc_now_iso():
    """Return current UTC time in ISO 8601 with milliseconds and 'Z'."""
    return (
        datetime.datetime.now(datetime.UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )

def get_video_metadata(video_path):
    """Extract video metadata using ffprobe."""
    try:
        cmd = [
            "ffprobe",
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=duration,r_frame_rate",
            "-of", "json",
            video_path,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=10, check=False
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            streams = data.get("streams", [])
            if streams:
                stream = streams[0]
                duration = float(stream.get("duration", 120.0))
                fps_str = stream.get("r_frame_rate", "30/1")
                if "/" in fps_str:
                    num, den = fps_str.split("/")
                    fps = float(num) / float(den) if float(den) > 0 else 30.0
                else:
                    fps = float(fps_str)
                return duration, fps
    except Exception as e:
        print(f"⚠️ Could not get metadata for {video_path}: {e}")
    return 120.0, 30.0

def generate_thumbnail(video_path, thumbnail_path, time_offset=1.0):
    """Generate a thumbnail from a video file."""
    try:
        # Check if ffmpeg is available
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        
        cmd = [
            "ffmpeg",
            "-i", video_path,
            "-ss", str(time_offset),
            "-vframes", "1",
            "-vf", "scale=320:-1",
            "-q:v", "2",
            "-y",
            thumbnail_path,
        ]
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        )
        return result.returncode == 0 and os.path.exists(thumbnail_path)
    except Exception as e:
        print(f"⚠️ Thumbnail generation failed: {e}")
        return False

def recreate_state():
    """Recreate state from existing video files."""
    print("=" * 60)
    print("🔄 Recreating State from Existing Videos")
    print("=" * 60)
    
    # Check if uploads folder exists
    if not os.path.exists(UPLOAD_FOLDER):
        print(f"❌ Uploads folder not found: {UPLOAD_FOLDER}")
        return
    
    # Find video files
    video_files = []
    for file in os.listdir(UPLOAD_FOLDER):
        file_path = os.path.join(UPLOAD_FOLDER, file)
        if os.path.isfile(file_path):
            ext = os.path.splitext(file)[1].lower()
            if ext in ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v']:
                # Skip files that are thumbnails
                if not file.endswith('_thumb.jpg'):
                    video_files.append(file)
    
    if not video_files:
        print("❌ No video files found in uploads folder")
        return
    
    print(f"📹 Found {len(video_files)} video file(s) in uploads folder")
    print("-" * 60)
    
    # Create new state
    new_state = {
        "users": {
            "testuser@example.com": {
                "name": "Test User", 
                "password": "YourSecurePassword123"
            }
        },
        "videos": [],
        "jobs": {},
        "sessions": {},
        "timestamp": datetime.datetime.now().isoformat(),
    }
    
    # Process each video
    for file_name in video_files:
        print(f"\n📹 Processing: {file_name}")
        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        file_size = os.path.getsize(file_path)
        
        # Get metadata
        duration, fps = get_video_metadata(file_path)
        
        # Generate thumbnail
        thumbnail_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
        thumbnail_url = None
        
        if generate_thumbnail(file_path, thumbnail_path):
            thumbnail_url = f"/thumbnails/{thumbnail_filename}"
            print(f"   ✅ Thumbnail generated: {thumbnail_filename}")
        else:
            print(f"   ⚠️ Could not generate thumbnail")
        
        # Create video entry
        video_key = str(uuid.uuid4())
        project = {
            "key": video_key,
            "name": os.path.splitext(file_name)[0],
            "file_name": file_name,
            "uploaded": utc_now_iso(),
            "last_opened": None,
            "duration": duration,
            "fps": fps,
            "file_size": file_size,
            "segment_count": 0,
            "languages": ["en"],
            "thumbnail_url": thumbnail_url,
            "segmentation_done": False,
            "segmentation_progress": 0,
        }
        new_state["videos"].append(project)
        print(f"   ✅ Added to state with key: {video_key[:8]}...")
    
    # Save state
    print("\n" + "-" * 60)
    try:
        with open(STATE_FILE, "wb") as f:
            pickle.dump(new_state, f)
        print(f"✅ State saved to {STATE_FILE}")
        print(f"   - {len(new_state['videos'])} video(s)")
        print(f"   - {len(new_state['users'])} user(s)")
    except Exception as e:
        print(f"❌ Failed to save state: {e}")
        return
    
    print("\n" + "=" * 60)
    print("📊 SUMMARY")
    print(f"   Videos found: {len(video_files)}")
    print(f"   Videos in state: {len(new_state['videos'])}")
    print(f"   Thumbnails: {'✅ Generated' if any(v.get('thumbnail_url') for v in new_state['videos']) else '❌ None'}")
    print("=" * 60)
    print("\n💡 Restart your Flask server to see the changes!")

if __name__ == "__main__":
    recreate_state()