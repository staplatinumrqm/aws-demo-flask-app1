import hashlib
import os
import time
from datetime import datetime

from flask import Flask, jsonify, render_template, request
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text

db = SQLAlchemy()


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

    if test_config:
        app.config.update(test_config)

    db.init_app(app)
    _register_routes(app)
    return app


def _register_routes(app):
    @app.route("/")
    def home():
        try:
            count = Item.query.count()
        except Exception:
            count = None
        return render_template("index.html", item_count=count)

    @app.route("/health")
    def health():
        # Liveness + DB connectivity (the ALB target group polls this).
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

    @app.route("/api/cpu")
    def cpu_burn():
        # Deliberately CPU-bound work to exercise autoscaling under load testing.
        # ?ms=<int> controls roughly how long to spin (capped to protect the box).
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
