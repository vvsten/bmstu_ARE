"""Tests for server.py endpoints."""

import io

# --- Health & Readiness ---


def test_health_check(client):
    response = client.get("/health")
    assert response.status_code == 200


def test_ready_check(client):
    response = client.get("/ready")
    assert response.status_code == 200


# --- Model Endpoints ---


def test_list_models(client):
    response = client.get("/v1/models")
    assert response.status_code == 200
    data = response.json()
    assert data["object"] == "list"
    assert len(data["data"]) == 1
    assert data["data"][0]["id"] == "ai-sage/GigaAM-Multilingual"
    assert data["data"][0]["object"] == "model"
    assert data["data"][0]["owned_by"] == "ai-sage"

# --- Transcription ---


def test_transcription_success(client, sample_audio_bytes):
    files = {"file": ("test.wav", io.BytesIO(sample_audio_bytes), "audio/wav")}
    response = client.post("/v1/audio/transcriptions", files=files)
    assert response.status_code == 200
    assert "text" in response.json()
    assert response.json()["text"] == "Привет мир"


def test_transcription_no_file(client):
    response = client.post("/v1/audio/transcriptions")
    assert response.status_code == 422


def test_transcription_wrong_model(client, sample_audio_bytes):
    files = {"file": ("test.wav", io.BytesIO(sample_audio_bytes), "audio/wav")}
    response = client.post(
        "/v1/audio/transcriptions",
        files=files,
        data={"model": "wrong-model"},
    )
    assert response.status_code == 400

