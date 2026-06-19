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
