"""Tests for the RabbitMQ avatar-processing pipeline.

The producer is tested via its graceful-degradation contract (no broker required);
the worker's thumbnail generation is tested directly against Pillow.
"""

import io
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

import app as appmod  # noqa: E402


# ── Producer / connection-string helpers ──────────────────────────────────────
def test_rabbitmq_url_none_when_host_unset(monkeypatch):
    monkeypatch.delenv("RABBITMQ_HOST", raising=False)
    assert appmod._rabbitmq_url() is None


def test_rabbitmq_url_built_from_parts(monkeypatch):
    monkeypatch.setenv("RABBITMQ_HOST", "rabbitmq.flask-pipeline.local")
    monkeypatch.setenv("RABBITMQ_USER", "app")
    monkeypatch.setenv("RABBITMQ_PASSWORD", "s3cret")
    monkeypatch.setenv("RABBITMQ_PORT", "5672")
    assert appmod._rabbitmq_url() == "amqp://app:s3cret@rabbitmq.flask-pipeline.local:5672/"


def test_publish_noops_when_messaging_disabled(monkeypatch):
    # No RABBITMQ_HOST → publish must return without importing/contacting pika.
    monkeypatch.delenv("RABBITMQ_HOST", raising=False)
    appmod._publish_avatar_job(1, "avatars/1/x.png")  # must not raise


def test_publish_is_best_effort_when_broker_unreachable(monkeypatch):
    # Host set but unreachable → the producer swallows the error (upload path
    # must never fail because the queue is down).
    monkeypatch.setenv("RABBITMQ_HOST", "169.254.0.1")  # unroutable test address
    monkeypatch.setenv("RABBITMQ_PORT", "5672")
    appmod._publish_avatar_job(1, "avatars/1/x.png")  # must not raise


# ── Worker thumbnail generation ───────────────────────────────────────────────
def _png_bytes(size):
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", size, (10, 120, 200)).save(buf, format="PNG")
    return buf.getvalue()


def test_make_thumbnail_shrinks_within_bounds():
    pytest.importorskip("PIL")
    from PIL import Image

    import worker

    original = _png_bytes((512, 384))
    thumb_bytes, content_type = worker._make_thumbnail(original, "png")

    assert content_type == "image/png"
    with Image.open(io.BytesIO(thumb_bytes)) as img:
        assert img.width <= 128 and img.height <= 128
        # aspect ratio preserved (4:3 → wider than tall)
        assert img.width > img.height
    assert len(thumb_bytes) < len(original)


def test_make_thumbnail_jpeg_format():
    pytest.importorskip("PIL")
    import worker

    thumb_bytes, content_type = worker._make_thumbnail(_png_bytes((200, 200)), "jpg")
    assert content_type == "image/jpeg"
    assert thumb_bytes[:2] == b"\xff\xd8"  # JPEG SOI marker
