"""Model loader for GigaAM transcription model."""

import logging

from transformers import AutoModel

logging.basicConfig(level=logging.DEBUG, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


class ModelLoader:
    """Loads and manages the GigaAM transcription model."""

    def __init__(self, model_name: str = "ai-sage/GigaAM-Multilingual", revision: str = "ctc"):
        self.model_name = model_name
        self.revision = revision
        self.model = None

    def load(self) -> None:
        """Load the model from pretrained weights."""
        logger.debug(f"Loading model {self.model_name} (revision={self.revision})...")
        self.model = AutoModel.from_pretrained(
            self.model_name,
            revision=self.revision,
            trust_remote_code=True,
        )
        logger.debug("Model loaded successfully.")

    def transcribe(self, audio_path: str) -> dict:
        """Transcribe audio file to text."""
        if self.model is None:
            raise RuntimeError("Model not loaded. Call load() first.")
        logger.debug(f"Transcribing audio: {audio_path}")
        result = self.model.transcribe(audio_path)
        logger.debug(f"Transcription completed: {result}")
        return result

    @property
    def is_ready(self) -> bool:
        """Check if model is loaded."""
        return self.model is not None
