import os
import sys

import pytest
from sqlalchemy.pool import StaticPool

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from app import create_app, db  # noqa: E402


@pytest.fixture
def app():
    # Single shared in-memory SQLite DB for the test (StaticPool keeps one
    # connection so the schema persists across requests).
    test_app = create_app(
        {
            "TESTING": True,
            "SQLALCHEMY_DATABASE_URI": "sqlite://",
            "SQLALCHEMY_ENGINE_OPTIONS": {
                "connect_args": {"check_same_thread": False},
                "poolclass": StaticPool,
            },
        }
    )
    with test_app.app_context():
        db.create_all()
        yield test_app


@pytest.fixture
def client(app):
    return app.test_client()


def test_health_ok(client):
    res = client.get("/health")
    assert res.status_code == 200
    body = res.get_json()
    assert body["status"] == "healthy"
    assert body["database"] == "connected"


def test_home_ok(client):
    assert client.get("/").status_code == 200


def test_items_empty_initially(client):
    res = client.get("/api/items")
    assert res.status_code == 200
    assert res.get_json() == []


def test_create_and_fetch_item(client):
    res = client.post("/api/items", json={"name": "widget", "description": "a thing"})
    assert res.status_code == 201
    created = res.get_json()
    assert created["name"] == "widget"
    item_id = created["id"]

    res = client.get(f"/api/items/{item_id}")
    assert res.status_code == 200
    assert res.get_json()["description"] == "a thing"


def test_create_item_requires_name(client):
    res = client.post("/api/items", json={"description": "no name"})
    assert res.status_code == 400


def test_delete_item(client):
    item_id = client.post("/api/items", json={"name": "temp"}).get_json()["id"]
    assert client.delete(f"/api/items/{item_id}").status_code == 204
    assert client.get(f"/api/items/{item_id}").status_code == 404


def test_get_missing_item_404(client):
    assert client.get("/api/items/99999").status_code == 404


def test_cpu_endpoint(client):
    res = client.get("/api/cpu?ms=10")
    assert res.status_code == 200
    assert res.get_json()["iterations"] > 0


# ── Profiles ──────────────────────────────────────────────────────────────────
def test_create_profile(client):
    res = client.post("/api/profiles", json={"username": "alice", "display_name": "Alice"})
    assert res.status_code == 201
    body = res.get_json()
    assert body["username"] == "alice"
    assert body["has_avatar"] is False


def test_profile_requires_username(client):
    assert client.post("/api/profiles", json={"display_name": "no user"}).status_code == 400


def test_duplicate_username_conflict(client):
    client.post("/api/profiles", json={"username": "bob"})
    assert client.post("/api/profiles", json={"username": "bob"}).status_code == 409


def test_get_missing_profile_404(client):
    assert client.get("/api/profiles/9999").status_code == 404


# ── Posts ───────────────────────────────────────────────────────────────────--
def test_create_and_list_posts(client):
    pid = client.post("/api/profiles", json={"username": "carol"}).get_json()["id"]
    res = client.post(f"/api/profiles/{pid}/posts", json={"title": "Hello", "body": "world"})
    assert res.status_code == 201
    assert res.get_json()["title"] == "Hello"

    listing = client.get(f"/api/profiles/{pid}/posts").get_json()
    assert len(listing) == 1


def test_post_requires_title(client):
    pid = client.post("/api/profiles", json={"username": "dave"}).get_json()["id"]
    assert client.post(f"/api/profiles/{pid}/posts", json={"body": "no title"}).status_code == 400


def test_post_on_missing_profile_404(client):
    assert client.post("/api/profiles/9999/posts", json={"title": "x"}).status_code == 404


# ── Avatar (validation paths that don't require S3) ───────────────────────────
def test_avatar_requires_file(client):
    pid = client.post("/api/profiles", json={"username": "erin"}).get_json()["id"]
    # No file field → 400, before any S3 interaction
    assert client.post(f"/api/profiles/{pid}/avatar").status_code == 400


def test_avatar_on_missing_profile_404(client):
    assert client.post("/api/profiles/9999/avatar").status_code == 404


# ── Web (server-rendered) pages ───────────────────────────────────────────────
def test_home_page_renders(client):
    res = client.get("/")
    assert res.status_code == 200
    assert b"Profiles" in res.data


def test_web_create_profile_and_view(client):
    res = client.post("/profiles", data={"username": "webuser", "display_name": "Web User"})
    assert res.status_code == 302
    page = client.get(res.headers["Location"])
    assert page.status_code == 200
    assert b"@webuser" in page.data


def _login(client, pid):
    with client.session_transaction() as sess:
        sess["user"] = {"profile_id": pid, "name": "Tester", "sub": "s", "email": "t@e.com"}


def test_web_create_post_shows_on_page(client):
    loc = client.post("/profiles", data={"username": "poster"}).headers["Location"]
    pid = int(loc.rstrip("/").split("/")[-1])
    _login(client, pid)  # write actions require being the logged-in owner
    assert client.post(f"/profiles/{pid}/posts", data={"title": "Hello UI"}).status_code == 302
    page = client.get(f"/profiles/{pid}")
    assert b"Hello UI" in page.data


def test_web_profile_404(client):
    assert client.get("/profiles/9999").status_code == 404


# ── Auth ──────────────────────────────────────────────────────────────────────
def test_post_requires_login(client):
    loc = client.post("/profiles", data={"username": "loner"}).headers["Location"]
    pid = int(loc.rstrip("/").split("/")[-1])
    client.post(f"/profiles/{pid}/posts", data={"title": "Sneaky"})  # no session
    assert b"Sneaky" not in client.get(f"/profiles/{pid}").data


def test_login_without_config_redirects_home(client):
    res = client.get("/login")
    assert res.status_code == 302  # no Cognito config in the default test app


def test_login_redirects_to_cognito():
    from sqlalchemy.pool import StaticPool

    from app import create_app, db

    cfg_app = create_app(
        {
            "TESTING": True,
            "SQLALCHEMY_DATABASE_URI": "sqlite://",
            "SQLALCHEMY_ENGINE_OPTIONS": {
                "connect_args": {"check_same_thread": False},
                "poolclass": StaticPool,
            },
            "COGNITO_DOMAIN": "https://example.auth.us-east-1.amazoncognito.com",
            "COGNITO_CLIENT_ID": "abc123",
            "APP_BASE_URL": "https://app.example.com",
        }
    )
    with cfg_app.app_context():
        db.create_all()
    res = cfg_app.test_client().get("/login")
    assert res.status_code == 302
    assert "/oauth2/authorize" in res.headers["Location"]
    assert "identity_provider=Google" in res.headers["Location"]
