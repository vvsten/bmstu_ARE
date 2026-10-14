import argparse

import soundfile as sf
import torch


def create_parser():
    """Create argument parser for TTS synthesis."""
    parser = argparse.ArgumentParser(description="Генерация речи с помощью Silero TTS")
    parser.add_argument("--text", required=True, help="Текст для озвучивания")
    parser.add_argument("--speaker", default="xenia", help="Голос для синтеза (по умолчанию: xenia)")
    parser.add_argument("--language", default="ru", help="Язык (по умолчанию: ru)")
    parser.add_argument("--output", default="output.wav", help="Имя выходного файла (по умолчанию: output.wav)")
    return parser


def synthesize_speech(text, speaker="xenia", language="ru", output="output.wav"):
    """Generate speech from text using Silero TTS."""
    model, _ = torch.hub.load(
        repo_or_dir="snakers4/silero-models",
        model="silero_tts",
        language=language,
        speaker="v5_ru",
    )


    audio = model.apply_tts(text=text, speaker=speaker)
    sf.write(output, audio, samplerate=48000)
    return output


if __name__ == "__main__":
    parser = create_parser()
    args = parser.parse_args()
    synthesize_speech(
        text=args.text,
        speaker=args.speaker,
        language=args.language,
        output=args.output,
    )
