#!/usr/bin/env python3
"""Standalone script to generate thumbnails for all videos."""

import os
import sys
import subprocess
import json
import pickle
from pathlib import Path

# Get the directory where this script is located
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
UPLOAD_FOLDER = os.path.join(SCRIPT_DIR, "uploads")
STATE_FILE = os.path.join(SCRIPT_DIR, "server_state.pkl")

def generate_video_thumbnail(video_path, thumbnail_path, time_offset=1.0):
    """Generate a thumbnail from a video file using ffmpeg."""
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
        if result.returncode == 0 and os.path.exists(thumbnail_path):
            return True
        print(f"❌ FFmpeg failed for {os.path.basename(video_path)}: {result.stderr[:200]}")
        return False
    except subprocess.TimeoutExpired:
        print(f"❌ FFmpeg timeout for {os.path.basename(video_path)}")
        return False
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"❌ FFmpeg error: {e}")
        print("   Make sure ffmpeg is installed and in your PATH")
        return False

def load_state():
    """Load server state from disk."""
    if not os.path.exists(STATE_FILE):
        print("⚠️ No state file found.")
        return None
    
    try:
        with open(STATE_FILE, "rb") as f:
            state = pickle.load(f)
        return state
    except Exception as e:
        print(f"❌ Failed to load state: {e}")
        return None

def save_state(state):
    """Save server state to disk."""
    try:
        with open(STATE_FILE, "wb") as f:
            pickle.dump(state, f)
        print("✅ State saved")
        return True
    except Exception as e:
        print(f"❌ Failed to save state: {e}")
        return False

def main():
    """Main function to generate thumbnails."""
    print("=" * 60)
    print("🎬 Thumbnail Generator for Videos")
    print("=" * 60)
    
    # Check if uploads folder exists
    if not os.path.exists(UPLOAD_FOLDER):
        print(f"❌ Uploads folder not found: {UPLOAD_FOLDER}")
        return
    
    # Load state
    state = load_state()
    if not state:
        print("❌ Could not load state. Exiting.")
        return
    
    videos = state.get("videos", [])
    if not videos:
        print("⚠️ No videos found in state.")
        return
    
    print(f"📹 Found {len(videos)} video(s) in state")
    print("-" * 60)
    
    # Find video files in uploads folder
    video_files = {}
    for file in os.listdir(UPLOAD_FOLDER):
        file_path = os.path.join(UPLOAD_FOLDER, file)
        if os.path.isfile(file_path):
            # Check if it's a video file
            ext = os.path.splitext(file)[1].lower()
            if ext in ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v']:
                video_files[file] = file_path
    
    print(f"📂 Found {len(video_files)} video file(s) in uploads folder")
    print("-" * 60)
    
    # Generate thumbnails
    regenerated = 0
    skipped = 0
    
    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            print(f"⚠️ Skipping video entry with no filename")
            skipped += 1
            continue
        
        # Check if file exists
        if file_name not in video_files:
            print(f"⚠️ File not found: {file_name}")
            skipped += 1
            continue
        
        file_path = video_files[file_name]
        
        # Check if thumbnail already exists
        thumbnail_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
        
        if os.path.exists(thumbnail_path):
            print(f"✅ Thumbnail already exists: {thumbnail_filename}")
            # Update state if thumbnail_url is missing
            if not video.get("thumbnail_url"):
                video["thumbnail_url"] = f"/thumbnails/{thumbnail_filename}"
                regenerated += 1
            continue
        
        # Generate thumbnail
        print(f"🖼️ Generating thumbnail for: {file_name}")
        if generate_video_thumbnail(file_path, thumbnail_path):
            video["thumbnail_url"] = f"/thumbnails/{thumbnail_filename}"
            regenerated += 1
            print(f"   ✅ Generated: {thumbnail_filename}")
        else:
            print(f"   ❌ Failed to generate thumbnail")
            video["thumbnail_url"] = None
    
    # Save state if changes were made
    if regenerated > 0:
        print("-" * 60)
        print(f"📝 Saving state with {regenerated} new thumbnail(s)...")
        save_state(state)
    else:
        print("-" * 60)
        print("ℹ️ No new thumbnails were generated")
    
    # Summary
    print("-" * 60)
    print("📊 SUMMARY")
    print(f"   Total videos in state: {len(videos)}")
    print(f"   Video files found: {len(video_files)}")
    print(f"   Thumbnails generated/updated: {regenerated}")
    print(f"   Skipped: {skipped}")
    print("=" * 60)

if __name__ == "__main__":
    main()