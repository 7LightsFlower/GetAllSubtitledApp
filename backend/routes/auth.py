"""Authentication routes for user registration, login, session checks, and Dex proxying."""

import uuid
import requests

from flask import Blueprint, jsonify, request

from ..config import INTERNAL_SERVER_URL, is_allowed_server
from ..state import users, save_state

bp = Blueprint("auth", __name__)


@bp.route("/register", methods=["POST"])
def register():
    """Register a new user and return an authentication token."""
    email = request.form.get("email")
    password = request.form.get("password")
    name = request.form.get("name", "")
    if not email or not password:
        return jsonify({"message": "Email and password required"}), 400
    if email in users:
        return jsonify({"message": "User already exists"}), 400
    users[email] = {"name": name, "password": password}
    save_state()
    return (
        jsonify(
            {"token": str(uuid.uuid4()), "message": "User registered successfully"}
        ),
        201,
    )


@bp.route("/login", methods=["POST"])
def login():
    """Authenticate a user and return an authentication token."""
    email = request.form.get("email")
    password = request.form.get("password")
    if not email or not password:
        return jsonify({"message": "Email and password required"}), 400
    user = users.get(email)
    if not user or user["password"] != password:
        return jsonify({"message": "Invalid credentials"}), 401
    return jsonify({"token": str(uuid.uuid4()), "message": "Login successful"}), 200


@bp.route("/check-session", methods=["GET"])
def check_session():
    """Check whether the request has an authenticated session."""
    headers = {}
    auth = request.headers.get("Authorization")
    if auth:
        headers["Authorization"] = auth
    forwarded_user = request.headers.get("X-Forwarded-User")
    if forwarded_user:
        headers["X-Forwarded-User"] = forwarded_user
    try:
        resp = requests.get(
            INTERNAL_SERVER_URL,
            headers=headers,
            allow_redirects=False,
            timeout=10,
            verify=False,
        )
        final_url = resp.url if hasattr(resp, "url") else INTERNAL_SERVER_URL
        is_login = resp.status_code == 200 and (
            "Log in to dex" in resp.text or "dex-container" in resp.text
        )
        authenticated = not ("dex" in final_url or resp.status_code == 302 or is_login)
        return jsonify({"authenticated": authenticated}), 200
    except requests.exceptions.RequestException:
        return jsonify({"authenticated": False, "error": "Request failed"}), 200


@bp.route("/dex/token", methods=["POST"])
def dex_token():
    """Proxy a token request to the selected Dex server."""
    requested = request.headers.get("X-Target-Server")
    server = (
        requested.rstrip("/") if is_allowed_server(requested) else INTERNAL_SERVER_URL
    )
    resp = requests.post(
        f"{server}/dex/token",
        data=request.get_data(),
        headers={k: v for k, v in request.headers if k.lower() != "host"},
        allow_redirects=False,
        timeout=30,
        verify=False,
    )
    return (resp.content, resp.status_code, resp.headers.items())


@bp.route("/dex/userinfo", methods=["GET"])
def dex_userinfo():
    """Proxy a user info request to the selected Dex server."""
    requested = request.headers.get("X-Target-Server")
    server = (
        requested.rstrip("/") if is_allowed_server(requested) else INTERNAL_SERVER_URL
    )
    try:
        headers = {k: v for k, v in request.headers if k.lower() != "host"}
        resp = requests.get(
            f"{server}/dex/userinfo",
            headers=headers,
            allow_redirects=False,
            timeout=30,
            verify=False,
        )
        return (resp.content, resp.status_code, resp.headers.items())
    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Proxy error: {e}"}), 500
