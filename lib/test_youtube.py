# test_youtube_formats.py
import yt_dlp

URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

ydl_opts = {
    "quiet": True,
    "no_warnings": True,
}

with yt_dlp.YoutubeDL(ydl_opts) as ydl:
    try:
        info = ydl.extract_info(URL, download=False)
        print(f"Title: {info.get('title')}")
        print(f"Duration: {info.get('duration')}")
        print("\nAvailable formats:")
        for fmt in info.get("formats", [])[:10]:  # Show first 10 formats
            print(
                f"  {fmt.get('format_id')}: {fmt.get('ext')} - {fmt.get('format_note', '')} - {fmt.get('vcodec')} - {fmt.get('acodec')}"
            )
    except yt_dlp.utils.DownloadError as e:
        print(f"Error: {e}")
