"""End-to-end API test. Runs against SQLite + local disk by default.

Set PGHOST/PGUSER/PGPASSWORD/PGDATABASE to run it against Postgres, and VIDEOS_BUCKET to test
S3 uploads (S3 is faked with moto, nothing touches AWS):

    cd backend && pytest
"""

import io
import os
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ.setdefault("REACTIONS_DB", os.path.join(tempfile.mkdtemp(), "test.db"))

S3_MODE = bool(os.environ.get("VIDEOS_BUCKET"))


@pytest.fixture(scope="module")
def client():
    if S3_MODE:
        import boto3
        from moto import mock_aws

        with mock_aws():
            boto3.client("s3", region_name="us-east-1").create_bucket(Bucket=os.environ["VIDEOS_BUCKET"])
            yield from _client()
    else:
        yield from _client()


def _client():
    from fastapi.testclient import TestClient

    import main

    with TestClient(main.app) as c:
        yield c


def test_health_and_demo_seed(client):
    assert client.get("/health").json() == {"ok": True}
    assert client.get("/sessions/demo").json()["reaction_count"] > 0


def test_session_lifecycle(client):
    created = client.post(
        "/sessions",
        json={
            "id": "t1",
            "name": "test",
            "reactions": [
                {"timestamp": 127.4, "type": "Joy", "intensity": 0.9, "confidence": 0.8},
                {"timestamp": 130.0, "type": "confusion", "intensity": 0.7, "breathing_rate": 14},
            ],
        },
    )
    assert created.status_code == 201, created.text
    assert client.post("/sessions", json={"id": "t1"}).status_code == 409

    reactions = client.get("/sessions/t1/reactions").json()
    assert reactions[0]["timestamp"] == 127.4  # no float precision loss
    assert reactions[0]["type"] == "joy"
    assert len(client.get("/sessions/t1/reactions", params={"start": 128}).json()) == 1
    assert client.get("/sessions/t1/insights").json()["summary"]["average_breathing_rate"] == 14

    chat = client.post("/sessions/t1/chat", json={"message": "where was the viewer confused?"}).json()
    assert 130.0 in chat["timestamps"]

    assert any(s["id"] == "t1" for s in client.get("/sessions").json())
    assert client.delete("/sessions/t1").status_code == 204
    assert client.get("/sessions/t1").status_code == 404


def test_video_upload(client):
    uploaded = client.post(
        "/sessions/upload-video", files={"file": ("my clip.mp4", io.BytesIO(b"x" * 1234), "video/mp4")}
    ).json()
    assert uploaded["size"] == 1234

    video = client.get(uploaded["video_url"], follow_redirects=False)
    if S3_MODE:
        assert video.status_code == 302
        assert "X-Amz-Signature" in video.headers["location"]
    else:
        import config

        assert video.status_code == 200 and len(video.content) == 1234
        (config.VIDEOS_DIR / uploaded["filename"]).unlink()


def test_demo_video_served_from_image(client):
    response = client.get("/api/videos/product_demo.mp4", headers={"range": "bytes=0-99"})
    assert response.status_code in (200, 206)
