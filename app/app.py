import hashlib
import os
import time
import uuid
from datetime import datetime

from urllib.parse import urlencode

from flask import (
    Flask,
    Response,
    abort,
    flash,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text

db = SQLAlchemy()

# Allowed avatar content types → file extension
ALLOWED_IMAGE_TYPES = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}
MAX_AVATAR_BYTES = 5 * 1024 * 1024  # 5 MB


class Item(db.Model):
    __tablename__ = "items"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    description = db.Column(db.Text, nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "created_at": self.created_at.isoformat() + "Z",
        }


class Profile(db.Model):
    __tablename__ = "profiles"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True, nullable=False)
    display_name = db.Column(db.String(120), nullable=False, default="")
    bio = db.Column(db.Text, nullable=False, default="")
    avatar_key = db.Column(db.String(256))
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    posts = db.relationship(
        "Post", backref="profile", cascade="all, delete-orphan", lazy=True
    )

    def to_dict(self):
        return {
            "id": self.id,
            "username": self.username,
            "display_name": self.display_name,
            "bio": self.bio,
            "has_avatar": self.avatar_key is not None,
            "avatar_url": f"/api/profiles/{self.id}/avatar" if self.avatar_key else None,
            "created_at": self.created_at.isoformat() + "Z",
        }


class Post(db.Model):
    __tablename__ = "posts"

    id = db.Column(db.Integer, primary_key=True)
    profile_id = db.Column(db.Integer, db.ForeignKey("profiles.id"), nullable=False)
    title = db.Column(db.String(200), nullable=False)
    body = db.Column(db.Text, nullable=False, default="")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "profile_id": self.profile_id,
            "title": self.title,
            "body": self.body,
            "created_at": self.created_at.isoformat() + "Z",
        }


class AuthUser(db.Model):
    # Links a Cognito (Google) identity to a profile. A new table, so create_all
    # provisions it without touching the existing profiles table.
    __tablename__ = "auth_users"

    id = db.Column(db.Integer, primary_key=True)
    cognito_sub = db.Column(db.String(128), unique=True, nullable=False)
    email = db.Column(db.String(255))
    profile_id = db.Column(db.Integer, db.ForeignKey("profiles.id"), nullable=False)


_s3_client = None


def _s3():
    # Lazy import + cache so the test suite doesn't require boto3 / AWS creds.
    global _s3_client
    if _s3_client is None:
        import boto3

        _s3_client = boto3.client("s3")
    return _s3_client


def _store_avatar(bucket, profile, file):
    """Validate + upload an avatar to S3. Returns (status_code, error_or_none)."""
    if file is None or file.filename == "":
        return 400, "a file is required"
    if file.mimetype not in ALLOWED_IMAGE_TYPES:
        return 400, f"unsupported type '{file.mimetype}' (png/jpeg/webp)"
    if not bucket:
        return 503, "avatar storage is not configured"

    ext = ALLOWED_IMAGE_TYPES[file.mimetype]
    key = f"avatars/{profile.id}/{uuid.uuid4().hex}.{ext}"
    _s3().put_object(Bucket=bucket, Key=key, Body=file.read(), ContentType=file.mimetype)

    old_key = profile.avatar_key
    profile.avatar_key = key
    db.session.commit()
    if old_key:
        try:
            _s3().delete_object(Bucket=bucket, Key=old_key)
        except Exception:
            pass  # best-effort cleanup of the previous avatar
    return 201, None


def _database_uri():
    """Postgres in production (from injected env), SQLite locally / in tests."""
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    host = os.environ.get("DB_HOST")
    if host:
        user = os.environ["DB_USER"]
        password = os.environ["DB_PASSWORD"]
        name = os.environ.get("DB_NAME", "appdb")
        port = os.environ.get("DB_PORT", "5432")
        return f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{name}"
    return "sqlite:///app.db"


def create_app(test_config=None):
    app = Flask(__name__)
    app.config["SQLALCHEMY_DATABASE_URI"] = _database_uri()
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    app.config["MAX_CONTENT_LENGTH"] = MAX_AVATAR_BYTES
    app.config["AVATAR_BUCKET"] = os.environ.get("AVATAR_BUCKET")
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret-change-me")
    app.config["COGNITO_DOMAIN"] = os.environ.get("COGNITO_DOMAIN")
    app.config["COGNITO_CLIENT_ID"] = os.environ.get("COGNITO_CLIENT_ID")
    app.config["COGNITO_CLIENT_SECRET"] = os.environ.get("COGNITO_CLIENT_SECRET")
    app.config["APP_BASE_URL"] = os.environ.get("APP_BASE_URL")

    if test_config:
        app.config.update(test_config)

    db.init_app(app)

    @app.context_processor
    def _inject_user():
        return {"current_user": session.get("user")}

    _register_auth_routes(app)
    _register_web_routes(app)
    _register_api_routes(app)
    return app


def _create_profile_for_login(email, name):
    base = "".join(c for c in (email.split("@")[0] if email else "user").lower()
                   if c.isalnum() or c in "._-") or "user"
    username, i = base, 1
    while Profile.query.filter_by(username=username).first():
        i += 1
        username = f"{base}{i}"
    profile = Profile(username=username, display_name=name or username, bio="")
    db.session.add(profile)
    db.session.commit()
    return profile


def _register_auth_routes(app):
    @app.route("/login")
    def login():
        domain = app.config.get("COGNITO_DOMAIN")
        client_id = app.config.get("COGNITO_CLIENT_ID")
        base = app.config.get("APP_BASE_URL")
        if not (domain and client_id and base):
            flash("Login is not configured yet.", "error")
            return redirect(url_for("home"))
        params = urlencode({
            "client_id": client_id,
            "response_type": "code",
            "scope": "openid email profile",
            "redirect_uri": f"{base}/auth/callback",
            "identity_provider": "Google",
        })
        return redirect(f"{domain}/oauth2/authorize?{params}")

    @app.route("/auth/callback")
    def auth_callback():
        code = request.args.get("code")
        domain = app.config.get("COGNITO_DOMAIN")
        client_id = app.config.get("COGNITO_CLIENT_ID")
        client_secret = app.config.get("COGNITO_CLIENT_SECRET") or ""
        base = app.config.get("APP_BASE_URL")
        if not (code and domain and client_id and base):
            flash("Login failed.", "error")
            return redirect(url_for("home"))

        import requests  # lazy import so tests don't need it

        token_res = requests.post(
            f"{domain}/oauth2/token",
            data={
                "grant_type": "authorization_code",
                "client_id": client_id,
                "code": code,
                "redirect_uri": f"{base}/auth/callback",
            },
            auth=(client_id, client_secret),
            timeout=10,
        )
        if token_res.status_code != 200:
            flash("Login failed during token exchange.", "error")
            return redirect(url_for("home"))

        access_token = token_res.json().get("access_token")
        info = requests.get(
            f"{domain}/oauth2/userInfo",
            headers={"Authorization": f"Bearer {access_token}"},
            timeout=10,
        ).json()

        sub = info.get("sub")
        email = info.get("email", "")
        name = info.get("name") or (email.split("@")[0] if email else "user")

        auth_user = AuthUser.query.filter_by(cognito_sub=sub).first()
        if auth_user is None:
            profile = _create_profile_for_login(email, name)
            auth_user = AuthUser(cognito_sub=sub, email=email, profile_id=profile.id)
            db.session.add(auth_user)
            db.session.commit()

        session["user"] = {"sub": sub, "email": email, "name": name,
                           "profile_id": auth_user.profile_id}
        flash("Signed in with Google.", "success")
        return redirect(url_for("web_profile", pid=auth_user.profile_id))

    @app.route("/logout")
    def logout():
        session.pop("user", None)
        domain = app.config.get("COGNITO_DOMAIN")
        client_id = app.config.get("COGNITO_CLIENT_ID")
        base = app.config.get("APP_BASE_URL")
        if domain and client_id and base:
            params = urlencode({"client_id": client_id, "logout_uri": f"{base}/"})
            return redirect(f"{domain}/logout?{params}")
        return redirect(url_for("home"))


# ── Web (server-rendered) routes ──────────────────────────────────────────────
def _register_web_routes(app):
    @app.route("/")
    def home():
        try:
            profiles = Profile.query.order_by(Profile.id.desc()).limit(50).all()
            posts = Post.query.order_by(Post.id.desc()).limit(15).all()
        except Exception:
            profiles, posts = [], []
        return render_template("index.html", profiles=profiles, posts=posts)

    @app.route("/profiles/<int:pid>")
    def web_profile(pid):
        profile = db.session.get(Profile, pid)
        if profile is None:
            abort(404)
        posts = sorted(profile.posts, key=lambda p: p.id, reverse=True)
        return render_template("profile.html", profile=profile, posts=posts)

    @app.route("/profiles", methods=["POST"])
    def web_create_profile():
        username = (request.form.get("username") or "").strip()
        if not username:
            flash("Username is required.", "error")
            return redirect(url_for("home"))
        if Profile.query.filter_by(username=username).first():
            flash("That username is already taken.", "error")
            return redirect(url_for("home"))
        profile = Profile(
            username=username,
            display_name=(request.form.get("display_name") or "").strip(),
            bio=(request.form.get("bio") or "").strip(),
        )
        db.session.add(profile)
        db.session.commit()
        flash("Profile created.", "success")
        return redirect(url_for("web_profile", pid=profile.id))

    @app.route("/profiles/<int:pid>/posts", methods=["POST"])
    def web_create_post(pid):
        profile = db.session.get(Profile, pid)
        if profile is None:
            abort(404)
        user = session.get("user")
        if not user or user.get("profile_id") != pid:
            flash("Sign in with Google to post on your own profile.", "error")
            return redirect(url_for("web_profile", pid=pid))
        title = (request.form.get("title") or "").strip()
        if not title:
            flash("Post title is required.", "error")
            return redirect(url_for("web_profile", pid=pid))
        db.session.add(
            Post(profile_id=pid, title=title, body=(request.form.get("body") or "").strip())
        )
        db.session.commit()
        flash("Post published.", "success")
        return redirect(url_for("web_profile", pid=pid))

    @app.route("/profiles/<int:pid>/avatar", methods=["POST"])
    def web_upload_avatar(pid):
        profile = db.session.get(Profile, pid)
        if profile is None:
            abort(404)
        user = session.get("user")
        if not user or user.get("profile_id") != pid:
            flash("Sign in with Google to change your own profile picture.", "error")
            return redirect(url_for("web_profile", pid=pid))
        status, error = _store_avatar(app.config.get("AVATAR_BUCKET"), profile, request.files.get("file"))
        flash("Profile picture updated." if error is None else error,
              "success" if error is None else "error")
        return redirect(url_for("web_profile", pid=pid))


# ── JSON API routes ───────────────────────────────────────────────────────────
def _register_api_routes(app):
    @app.route("/health")
    def health():
        try:
            db.session.execute(text("SELECT 1"))
            return jsonify({"status": "healthy", "database": "connected", "code": 200})
        except Exception as exc:
            return jsonify({"status": "unhealthy", "database": str(exc), "code": 503}), 503

    @app.route("/api/items", methods=["GET"])
    def list_items():
        items = Item.query.order_by(Item.id.desc()).limit(100).all()
        return jsonify([i.to_dict() for i in items])

    @app.route("/api/items", methods=["POST"])
    def create_item():
        data = request.get_json(silent=True) or {}
        name = (data.get("name") or "").strip()
        if not name:
            return jsonify({"error": "name is required"}), 400
        item = Item(name=name, description=(data.get("description") or "").strip())
        db.session.add(item)
        db.session.commit()
        return jsonify(item.to_dict()), 201

    @app.route("/api/items/<int:item_id>", methods=["GET"])
    def get_item(item_id):
        item = db.session.get(Item, item_id)
        if item is None:
            return jsonify({"error": "not found"}), 404
        return jsonify(item.to_dict())

    @app.route("/api/items/<int:item_id>", methods=["DELETE"])
    def delete_item(item_id):
        item = db.session.get(Item, item_id)
        if item is None:
            return jsonify({"error": "not found"}), 404
        db.session.delete(item)
        db.session.commit()
        return "", 204

    @app.route("/api/profiles", methods=["GET"])
    def list_profiles():
        profiles = Profile.query.order_by(Profile.id.desc()).limit(100).all()
        return jsonify([p.to_dict() for p in profiles])

    @app.route("/api/profiles", methods=["POST"])
    def create_profile():
        data = request.get_json(silent=True) or {}
        username = (data.get("username") or "").strip()
        if not username:
            return jsonify({"error": "username is required"}), 400
        if Profile.query.filter_by(username=username).first():
            return jsonify({"error": "username already taken"}), 409
        profile = Profile(
            username=username,
            display_name=(data.get("display_name") or "").strip(),
            bio=(data.get("bio") or "").strip(),
        )
        db.session.add(profile)
        db.session.commit()
        return jsonify(profile.to_dict()), 201

    @app.route("/api/profiles/<int:pid>", methods=["GET"])
    def get_profile(pid):
        profile = db.session.get(Profile, pid)
        if profile is None:
            return jsonify({"error": "not found"}), 404
        data = profile.to_dict()
        data["posts"] = [p.to_dict() for p in profile.posts]
        return jsonify(data)

    @app.route("/api/profiles/<int:pid>", methods=["DELETE"])
    def delete_profile(pid):
        profile = db.session.get(Profile, pid)
        if profile is None:
            return jsonify({"error": "not found"}), 404
        db.session.delete(profile)
        db.session.commit()
        return "", 204

    @app.route("/api/profiles/<int:pid>/posts", methods=["GET"])
    def list_posts(pid):
        if db.session.get(Profile, pid) is None:
            return jsonify({"error": "profile not found"}), 404
        posts = Post.query.filter_by(profile_id=pid).order_by(Post.id.desc()).all()
        return jsonify([p.to_dict() for p in posts])

    @app.route("/api/profiles/<int:pid>/posts", methods=["POST"])
    def create_post(pid):
        if db.session.get(Profile, pid) is None:
            return jsonify({"error": "profile not found"}), 404
        data = request.get_json(silent=True) or {}
        title = (data.get("title") or "").strip()
        if not title:
            return jsonify({"error": "title is required"}), 400
        post = Post(profile_id=pid, title=title, body=(data.get("body") or "").strip())
        db.session.add(post)
        db.session.commit()
        return jsonify(post.to_dict()), 201

    @app.route("/api/profiles/<int:pid>/avatar", methods=["POST"])
    def upload_avatar(pid):
        profile = db.session.get(Profile, pid)
        if profile is None:
            return jsonify({"error": "not found"}), 404
        status, error = _store_avatar(app.config.get("AVATAR_BUCKET"), profile, request.files.get("file"))
        if error is not None:
            return jsonify({"error": error}), status
        return jsonify(profile.to_dict()), 201

    @app.route("/api/profiles/<int:pid>/avatar", methods=["GET"])
    def get_avatar(pid):
        profile = db.session.get(Profile, pid)
        if profile is None or not profile.avatar_key:
            return jsonify({"error": "not found"}), 404
        bucket = app.config.get("AVATAR_BUCKET")
        if not bucket:
            return jsonify({"error": "avatar storage is not configured"}), 503
        obj = _s3().get_object(Bucket=bucket, Key=profile.avatar_key)
        return Response(
            obj["Body"].read(),
            mimetype=obj.get("ContentType", "application/octet-stream"),
        )

    @app.route("/api/cpu")
    def cpu_burn():
        target_ms = min(int(request.args.get("ms", 250)), 5000)
        deadline = time.perf_counter() + target_ms / 1000.0
        iterations = 0
        digest = b"seed"
        while time.perf_counter() < deadline:
            digest = hashlib.sha256(digest).digest()
            iterations += 1
        return jsonify({"target_ms": target_ms, "iterations": iterations})


# Module-level app for gunicorn (`app:app`).
app = create_app()

if __name__ == "__main__":
    with app.app_context():
        db.create_all()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)))
