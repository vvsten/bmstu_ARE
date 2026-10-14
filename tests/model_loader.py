"""Test mock of model_loader for server tests."""


class MockModel:
    """Mock model with transcribe callable that supports side_effect."""

    def __init__(self, result=None, side_effect=None):
        self.result = result or {"text": "Привет мир"}
        self.side_effect = side_effect

    def transcribe(self, audio_path: str) -> dict:
        if self.side_effect:
            raise self.side_effect
        return self.result


class ModelLoader:
    """Mock ModelLoader for testing."""

    def __init__(self, model_name: str = "test-model", revision: str = "test"):
        self.model_name = model_name
        self.revision = revision
        self.model = None

    def load(self) -> None:
        self.model = MockModel()

    def transcribe(self, audio_path: str) -> dict:
        if self.model is None:
            raise RuntimeError("Model not loaded. Call load() first.")
        return self.model.transcribe(audio_path)

    @property
    def is_ready(self) -> bool:
        return self.model is not None
