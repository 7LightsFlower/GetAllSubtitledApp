"""Persisting the server state; cleaning up and rebuilding the video list.

Split mechanically from the former lib/backend.py — code unchanged.
"""

import datetime
import hashlib
import logging
import os
import pickle
import shutil
import uuid

from .config import STATE_FILE, UPLOAD_FOLDER, jobs, sessions, users, videos


# ─── STATE PERSISTENCE ──────────────────────────────────────────────────


# Hash of the last state we actually wrote to disk. Used by save_state()
# to skip redundant writes when nothing meaningful changed.
# Store this in a mutable container so save_state() can update it without
# using a module-level global statement.
_state_cache = {"last_hash": None}


def _state_payload() -> dict:
    """The part of the state that actually matters for persistence.

    Kept separate from the on-disk blob so the 'timestamp' field does not
    invalidate the dedup hash on every call.
    """
    return {
        "users": users,
        "videos": videos,
        "jobs": jobs,
        "sessions": sessions,
    }


def save_state(force: bool = False):
    """Save server state to disk.

    Skips the write entirely when the meaningful state is byte-identical
    to the last successful save, unless `force=True` is passed.
    """
    try:
        payload = _state_payload()
        blob = pickle.dumps(payload)
        digest = hashlib.sha256(blob).hexdigest()

        if not force and digest == _state_cache["last_hash"]:
            # Nothing changed since the last write — don't touch the disk
            # and don't spam the log.
            return

        state = {
            **payload,
            "timestamp": datetime.datetime.now().isoformat(),
        }
        with open(STATE_FILE, "wb") as f:
            pickle.dump(state, f)

        _state_cache["last_hash"] = digest
        logging.info("State saved to %s", STATE_FILE)
    except (OSError, pickle.PickleError, TypeError, ValueError) as e:
        logging.error("Failed to save state: %s", e)


def load_state():
    """Load server state from disk."""
    if not os.path.exists(STATE_FILE):
        logging.info("No state file found. Starting with default state.")
        return False

    try:
        with open(STATE_FILE, "rb") as f:
            state = pickle.load(f)

        loaded_state = {
            "users": state.get("users", {}),
            "videos": state.get("videos", []),
            "jobs": state.get("jobs", {}),
            "sessions": state.get("sessions", {}),
        }
        # In place: the same dict/list objects are shared by every module.
        users.clear()
        users.update(loaded_state["users"])
        videos[:] = loaded_state["videos"]
        jobs.clear()
        jobs.update(loaded_state["jobs"])
        sessions.clear()
        sessions.update(loaded_state["sessions"])

        logging.info("State loaded from %s", STATE_FILE)
        logging.info("  - Users: %d", len(users))
        logging.info("  - Videos: %d", len(videos))
        logging.info("  - Jobs: %d", len(jobs))
        logging.info("  - Sessions: %d", len(sessions))

        # Verify video files still exist and update status
        for video in videos:
            file_name = video.get("file_name")
            if file_name:
                file_path = os.path.join(UPLOAD_FOLDER, file_name)
                if not os.path.exists(file_path):
                    logging.warning("Video file missing: %s", file_path)
                    video["file_missing"] = True
                else:
                    video["file_missing"] = False

        return True
    except (
        FileNotFoundError,
        OSError,
        pickle.PickleError,
        EOFError,
        AttributeError,
        TypeError,
        ValueError,
    ) as e:
        logging.error("Failed to load state: %s", e)
        return False


def clean_missing_videos():
    """Remove video entries whose files no longer exist on disk."""
    if not videos:
        return

    valid_videos = []
    removed_count = 0

    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            # Skip entries without a filename
            removed_count += 1
            logging.warning(
                "Removing video entry with no filename: %s",
                video.get("name", "Unknown"),
            )
            continue

        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if os.path.exists(file_path):
            valid_videos.append(video)
        else:
            removed_count += 1
            logging.warning(
                "Removing missing video: %s (key: %s)",
                file_name,
                video.get("key", "N/A"),
            )

            # Also remove any associated thumbnail
            thumb_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
            thumb_path = os.path.join(UPLOAD_FOLDER, thumb_filename)
            if os.path.exists(thumb_path):
                try:
                    os.remove(thumb_path)
                    logging.info("Removed orphaned thumbnail: %s", thumb_filename)
                except OSError as e:
                    logging.warning(
                        "Could not remove thumbnail %s: %s", thumb_filename, e
                    )

    if removed_count > 0:
        videos[:] = valid_videos
        save_state()
        logging.info(
            "🧹 Cleaned up %d missing video(s). %d video(s) remain.",
            removed_count,
            len(videos),
        )
    else:
        logging.info("✅ All %d video(s) are valid.", len(videos))


def cleanup_orphaned_data():
    """Remove orphaned sessions and jobs that reference non-existent videos."""
    # These dictionaries are mutated in place; rebinding their module-level
    # names is not necessary.
    session_store = sessions
    job_store = jobs

    # Get valid video keys
    valid_video_keys = {video.get("key") for video in videos if video.get("key")}

    # Clean up sessions
    orphaned_sessions = []
    for session_id, session in session_store.items():
        video_key = session.get("video_key")
        if video_key and video_key not in valid_video_keys:
            orphaned_sessions.append(session_id)
            logging.warning(
                "Removing orphaned session %s (video_key: %s)",
                _short_sid(session_id),
                video_key,
            )

            # Also remove session files if they exist
            session_dir = _session_dir(session_id)
            if os.path.exists(session_dir):
                try:
                    shutil.rmtree(session_dir)
                    logging.info("Removed session directory: %s", session_dir)
                except OSError as e:
                    logging.warning(
                        "Could not remove session directory %s: %s", session_dir, e
                    )

    for session_id in orphaned_sessions:
        del session_store[session_id]

    # Clean up jobs
    orphaned_jobs = []
    for job_id, job in job_store.items():
        video_key = job.get("video_key")
        if video_key and video_key not in valid_video_keys:
            orphaned_jobs.append(job_id)
            logging.warning(
                "Removing orphaned job %s (video_key: %s)", job_id, video_key
            )

    for job_id in orphaned_jobs:
        del job_store[job_id]

    if orphaned_sessions or orphaned_jobs:
        save_state()
        logging.info(
            "🧹 Cleaned up %d orphaned session(s) and %d orphaned job(s)",
            len(orphaned_sessions),
            len(orphaned_jobs),
        )


def regenerate_missing_thumbnails():
    """Regenerate thumbnails for videos whose thumbnail file is missing.

    The previous version only checked whether `thumbnail_url` was set,
    which meant a deleted `_thumb.jpg` was never rebuilt. We now verify
    the file actually exists on disk before skipping.
    """
    if not videos:
        return

    regenerated = 0
    for video in videos:
        file_name = video.get("file_name")
        if not file_name:
            continue

        file_path = os.path.join(UPLOAD_FOLDER, file_name)
        if not os.path.exists(file_path):
            continue

        thumbnail_filename = f"{os.path.splitext(file_name)[0]}_thumb.jpg"
        thumbnail_path = os.path.join(UPLOAD_FOLDER, thumbnail_filename)
        thumb_url = video.get("thumbnail_url")

        # URL claims a thumbnail exists AND the file is actually there → OK.
        if thumb_url and thumb_url != "None" and os.path.exists(thumbnail_path):
            continue

        # Otherwise (re)generate it.
        if generate_video_thumbnail(file_path, thumbnail_path):
            video["thumbnail_url"] = f"/thumbnails/{thumbnail_filename}"
            regenerated += 1
            logging.info("Generated thumbnail for %s", file_name)
        else:
            video["thumbnail_url"] = None

    if regenerated > 0:
        save_state()
        logging.info("🖼️ Regenerated %d thumbnail(s)", regenerated)


def rebuild_videos_from_disk():
    """Add `videos` entries for MP4s in UPLOAD_FOLDER that aren't
    tracked in the state file yet.

    Runs at startup, after load_state(). This is what makes the state
    file self-healing: if server_state.pkl is lost or reset, the next
    start repopulates the `videos` list from what's actually on disk.

    Files are matched by `file_name`, so a project that is already
    tracked — even one whose metadata drifted — is left untouched.

    Does not delete anything. Deletion of entries for files that no
    longer exist is handled by clean_missing_videos(), which runs
    right after this in __main__.
    """
    if not os.path.isdir(UPLOAD_FOLDER):
        return

    known = {v.get("file_name") for v in videos if v.get("file_name")}
    added = 0

    for filename in sorted(os.listdir(UPLOAD_FOLDER)):
        if not filename.lower().endswith(".mp4"):
            continue
        # Skip the derived artefacts the app creates alongside the
        # original. These are not "videos" in the UI sense — they are
        # stand-ins for the KIT pipeline.
        if "__greenscreen" in filename or "_converted" in filename:
            continue
        if filename in known:
            continue

        file_path = os.path.join(UPLOAD_FOLDER, filename)
        if not os.path.isfile(file_path):
            continue

        try:
            size = os.path.getsize(file_path)
            uploaded = file_mtime_iso(file_path)
        except OSError as e:
            logging.warning(
                "rebuild_videos: skipping %s (stat failed: %s)", filename, e
            )
            continue

        if size < 1000:
            logging.warning(
                "rebuild_videos: skipping %s (file too small: %d bytes)",
                filename,
                size,
            )
            continue

        # Pick up the existing thumbnail if there is one. Naming
        # convention: <stem>_thumb.jpg.
        stem = os.path.splitext(filename)[0]
        thumb_name = f"{stem}_thumb.jpg"
        thumb_path = os.path.join(UPLOAD_FOLDER, thumb_name)
        thumbnail_url = (
            f"/thumbnails/{thumb_name}" if os.path.exists(thumb_path) else None
        )

        # Best-effort duration/fps/codec. ffprobe is quick on a
        # local file and the values are only used for display.
        try:
            duration, fps, codec = get_video_metadata(file_path)
        except (OSError, ValueError, TypeError):
            duration, fps, codec = 0.0, 0.0, ""

        # Name: prefer a human-readable title. Fall back to the
        # filename stem if nothing better is available.
        display_name = stem
        # Source label. Matches the rule in _ensure_source_field():
        # a filename that mentions YouTube is treated as an import;
        # everything else is a desktop upload. Recovered entries are
        # still tagged "_recovered" so the debug endpoint can tell
        # them apart from fresh uploads.
        if "youtube" in filename.lower():
            source = "Imported (YouTube)"
        else:
            source = "Desktop Upload"

        videos.append(
            {
                "key": str(uuid.uuid4()),
                "name": display_name,
                "file_name": filename,
                "uploaded": uploaded,
                "last_opened": None,
                "duration": duration,
                "fps": fps,
                "codec": codec,
                "file_size": size,
                "segment_count": 0,
                "languages": ["en"],
                "thumbnail_url": thumbnail_url,
                "segmentation_done": False,
                "segmentation_progress": 0,
                # Mark so it's obvious in the debug endpoint that this
                # entry was recovered rather than uploaded.
                "_recovered": True,
                "source": source,
            }
        )
        added += 1

    if added:
        save_state()
        logging.info(
            "♻️ rebuild_videos_from_disk: recovered %d video(s) "
            "from %s. Total videos now: %d",
            added,
            UPLOAD_FOLDER,
            len(videos),
        )
    else:
        logging.info(
            "rebuild_videos_from_disk: no untracked videos found "
            "(%d already tracked)",
            len(videos),
        )


# ── Names from modules further down the chain ─────────────────────────
# They are only used inside functions. backend.app calls this once all
# modules are loaded, so the circular references resolve cleanly.
def _link_late_names():
    global _session_dir, _short_sid, file_mtime_iso
    global generate_video_thumbnail, get_video_metadata
    from .utils import _session_dir, _short_sid, file_mtime_iso
    from .video import generate_video_thumbnail, get_video_metadata
