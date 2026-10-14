import json
import logging
import os
import tempfile
import threading
import uuid

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from pydantic import BaseModel

from model_loader import ModelLoader

LOG_DIR = os.getenv("LOG_DIR", os.path.join(os.path.dirname(__file__), "logs"))
os.makedirs(LOG_DIR, exist_ok=True)

logger = logging.getLogger("voiceapi")
logger.setLevel(logging.DEBUG)

# stdout handler
_stdout_handler = logging.StreamHandler()
_stdout_handler.setFormatter(logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s"))
logger.addHandler(_stdout_handler)

# file handler (for Logstash)
_file_handler = logging.FileHandler(f"{LOG_DIR}/voiceapi.log")
_file_handler.setFormatter(logging.Formatter(json.dumps({
    "@timestamp": "%(asctime)s",
    "logger": "%(name)s",
    "level": "%(levelname)s",
    "message": "%(message)s",
})))
logger.addHandler(_file_handler)

MODEL_NAME = "ai-sage/GigaAM-Multilingual"
model_loaded = False
app = FastAPI(
    title="GigaAM API",
    description=f"API для транскрипции аудио с использованием {MODEL_NAME} модели",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json",
)


class Model(BaseModel):
    id: str
    object: str = "model"
    created: int
    owned_by: str = "ai-sage"


class ModelList(BaseModel):
    object: str = "list"
    data: list[Model]


class TranscriptionResponse(BaseModel):
    text: str


model_loader = ModelLoader()
INSTANCE_ID = str(uuid.uuid4())


def _load_model_background():
    """Load model in background thread to avoid blocking startup."""
    try:
        logger.info("Loading model in background...")
        model_loader.load()
        logger.info("Model loaded successfully")
    except Exception as e:
        logger.error(f"Failed to load model: {e}")


@app.on_event("startup")
async def startup_event():
    # Start model loading in background
    threading.Thread(target=_load_model_background, daemon=True).start()


@app.get("/health")
async def health_check():
    return {"status": "healthy", "loaded": model_loaded, "instance_id": INSTANCE_ID}


@app.get("/ready")
async def ready_check():
    if model_loader.is_ready:
        return {"status": "ready"}
    raise HTTPException(status_code=503, detail="Model not loaded")


@app.get("/v1/models")
async def list_models():
    return ModelList(
        data=[
            Model(
                id=MODEL_NAME,
                created=1718000000,
            )
        ]
    )


@app.post(
    "/v1/audio/transcriptions",
    tags=["Audio"],
    summary="Транскрипция аудио",
    description="Отправляет аудиофайл для транскрипции с использованием GigaAM модели.",
    response_model=TranscriptionResponse,
    responses={
        200: {
            "description": "Успешная транскрипция",
            "content": {"application/json": {"example": {"text": "Текст транскрипции"}}},
        },
        400: {"description": "Неверный запрос (нет файла, неверная модель)"},
        404: {"description": "Модель не найдена"},
        500: {"description": "Ошибка сервера при обработке аудио"},
    },
)
async def create_transcription(
    file: UploadFile = File(
        ...,
        description="Аудиофайл для транскрипции (wav, mp3, m4a, flac)",
        media_type="audio/*",
    ),
    model: str = Form(
        default=MODEL_NAME,
        description="Имя модели для транскрипции",
    ),
):
    if model != MODEL_NAME:
        raise HTTPException(status_code=400, detail=f"Model {model} not found")

    if not file.filename:
        raise HTTPException(status_code=400, detail="No file provided")

    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=os.path.splitext(file.filename)[1]) as temp_file:
            content = await file.read()
            temp_file.write(content)
            temp_path = temp_file.name

        try:
            transcription = model_loader.transcribe(temp_path)
            logger.debug(f"Transcription result: {transcription}")
            return transcription
        finally:
            os.unlink(temp_path)

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e)) from e


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
