# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Build the Flutter web frontend
#
# The repo's web/ directory is only the *source template*: its index.html still
# contains the $FLUTTER_BASE_HREF placeholder and files like flutter_bootstrap.js
# and main.dart.js do not exist yet. `flutter build web` compiles the Dart code
# in lib/ to JavaScript and writes the deployable app to build/web/.
#
# No maintained third-party Flutter Docker image tracks current versions, so we
# install the pinned official SDK from the release tarball instead.
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS web-builder

ARG FLUTTER_VERSION=3.47.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils unzip \
    && rm -rf /var/lib/apt/lists/*

# Install the pinned Flutter SDK (Dart SDK is bundled in the tarball)
RUN curl -fsSL \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar xJ -C /opt \
    && git config --global --add safe.directory /opt/flutter \
    && /opt/flutter/bin/flutter config --no-analytics \
    && /opt/flutter/bin/flutter --version

ENV PATH="/opt/flutter/bin:$PATH"

WORKDIR /build

# Copy the pubspec first so `flutter pub get` is cached in its own layer
# (only re-runs when the dependency list changes).
COPY ./pubspec.yaml ./pubspec.lock /build/
RUN flutter pub get

# Copy the rest of the project and build the web app (output: /build/build/web).
# API_BASE_URL defaults to '' => the frontend calls the API on its own origin
# (relative URLs like /login), which works because Nginx serves the frontend
# and proxies those paths to the Flask backend.
# Override to point the frontend at a different API origin:
#   docker build --build-arg API_BASE_URL=https://api.example.com
ARG API_BASE_URL=""
COPY . .
RUN flutter build web --release --no-wasm-dry-run \
    --dart-define=API_BASE_URL=${API_BASE_URL}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Flask API backend (only reachable via the Nginx proxy)
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3-slim AS backend

# ffmpeg/ffprobe: thumbnail generation + video metadata;
# curl: downloads from the internal server + container healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir Flask gunicorn requests flask-cors python-docx yt-dlp beautifulsoup4

WORKDIR /app

# Backend code (includes the *unbuilt* web/ source template, unused at runtime)
COPY . /app/
RUN rm -rf /app/web

# Single worker: users/videos/jobs/chunk_storage live in process memory,
# so multiple workers would see different state.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "8", "lib.backend:app"]

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: Nginx serving the built frontend, proxying API requests to Flask
# (default/final stage; the "backend" stage is selected via compose's
#  `target: backend`)
# ─────────────────────────────────────────────────────────────────────────────
FROM nginx:alpine AS web

COPY --from=web-builder /build/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
