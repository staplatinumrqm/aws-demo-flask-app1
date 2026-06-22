"""Avatar thumbnail worker.

Consumes `avatar_jobs` messages published by the Flask app when a user uploads a
profile picture, then:

    RabbitMQ -> download original from S3 -> Pillow thumbnail -> upload to S3 ->
    update Profile.thumbnail_key in Postgres -> ack.

Runs as its own ECS Fargate service from the same image as the web app, with the
container entry point overridden to `python -u worker.py`. Designed to be safe to
scale to N replicas: RabbitMQ round-robins messages and each is acked only after
the thumbnail is committed, so a crash mid-job re-queues the work.
"""

import io
import json
import os
import time

from app import AVATAR_QUEUE, Profile, _rabbitmq_url, _s3, create_app, db

THUMBNAIL_SIZE = (128, 128)
# Pillow format + S3 content type per source extension.
THUMB_FORMAT = {"png": ("PNG", "image/png"), "jpg": ("JPEG", "image/jpeg"),
                "webp": ("WEBP", "image/webp")}


def _make_thumbnail(image_bytes, ext):
    """Return (thumbnail_bytes, content_type) for the given original image."""
    from PIL import Image

    fmt, content_type = THUMB_FORMAT.get(ext, ("PNG", "image/png"))
    with Image.open(io.BytesIO(image_bytes)) as img:
        img = img.convert("RGB") if fmt == "JPEG" else img.copy()
        img.thumbnail(THUMBNAIL_SIZE)  # preserves aspect ratio, in place
        out = io.BytesIO()
        img.save(out, format=fmt)
    return out.getvalue(), content_type


def _process_job(app, bucket, profile_id, key):
    """Generate and store a thumbnail for one avatar. Returns True on success."""
    ext = key.rsplit(".", 1)[-1].lower()
    original = _s3().get_object(Bucket=bucket, Key=key)["Body"].read()
    thumb_bytes, content_type = _make_thumbnail(original, ext)

    thumb_key = f"thumbnails/{profile_id}/{key.rsplit('/', 1)[-1]}"
    _s3().put_object(Bucket=bucket, Key=thumb_key, Body=thumb_bytes,
                     ContentType=content_type)

    with app.app_context():
        profile = db.session.get(Profile, profile_id)
        if profile is None:
            print(f"profile {profile_id} gone; dropping job", flush=True)
            return True  # ack: nothing to update, don't re-queue forever
        # Only attach the thumbnail if it still matches the current avatar — the
        # user may have uploaded a newer one while this job was queued.
        if profile.avatar_key != key:
            print(f"avatar for {profile_id} changed; discarding stale thumb", flush=True)
            return True
        profile.thumbnail_key = thumb_key
        db.session.commit()
    print(f"thumbnail ready for profile {profile_id}: {thumb_key}", flush=True)
    return True


def _on_message(app, bucket):
    def handler(channel, method, _properties, body):
        try:
            job = json.loads(body)
            _process_job(app, bucket, job["profile_id"], job["key"])
            channel.basic_ack(delivery_tag=method.delivery_tag)
        except Exception as exc:  # noqa: BLE001
            # Don't re-queue a poison message in a tight loop; log and drop it.
            print(f"job failed, dropping: {exc}", flush=True)
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
    return handler


def main():
    url = _rabbitmq_url()
    if not url:
        raise SystemExit("RABBITMQ_HOST is not set; nothing to consume")
    bucket = os.environ.get("AVATAR_BUCKET")
    if not bucket:
        raise SystemExit("AVATAR_BUCKET is not set")

    app = create_app()
    # Ensure the schema exists (thumbnail_key column) before consuming.
    with app.app_context():
        for attempt in range(1, 31):
            try:
                db.create_all()
                break
            except Exception as exc:  # noqa: BLE001
                print(f"DB not ready ({attempt}/30): {exc}", flush=True)
                time.sleep(2)

    import pika

    params = pika.URLParameters(url)
    params.heartbeat = 30
    # Reconnect loop: the broker may start after / restart independently of us.
    while True:
        try:
            connection = pika.BlockingConnection(params)
            channel = connection.channel()
            channel.queue_declare(queue=AVATAR_QUEUE, durable=True)
            channel.basic_qos(prefetch_count=1)  # one in-flight job per worker
            channel.basic_consume(queue=AVATAR_QUEUE, on_message_callback=_on_message(app, bucket))
            print(f"worker consuming '{AVATAR_QUEUE}'", flush=True)
            channel.start_consuming()
        except pika.exceptions.AMQPConnectionError as exc:
            print(f"broker connection lost ({exc}); retrying in 5s", flush=True)
            time.sleep(5)
        except KeyboardInterrupt:
            print("worker shutting down", flush=True)
            break


if __name__ == "__main__":
    main()
