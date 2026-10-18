#!/usr/bin/env python3
"""Generate synthetic audition samples; never changes Coucou's voice settings.

Run with an isolated project Python environment containing qwen-tts (local) or
edge-tts (online). Qwen weights must already exist locally. Edge sends only the
explicit sample text to Microsoft's online Read Aloud service.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import time


TEXT = (
    "Olá, Pedro. Queres que abra a pasta de transferências? "
    "Posso ajudar-te a organizar os ficheiros e explicar o que estou a fazer, "
    "passo a passo."
)


def report(**values):
    print(json.dumps(values, ensure_ascii=False), flush=True)


def qwen(args):
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel

    if not args.model or not (args.model / "model.safetensors").is_file():
        raise SystemExit("Provide --model with the downloaded VoiceDesign directory")
    if not torch.cuda.is_available():
        raise SystemExit("No CUDA device available; refusing an accidental CPU benchmark")
    torch.set_num_threads(4)
    started = time.perf_counter()
    model = Qwen3TTSModel.from_pretrained(
        str(args.model.resolve()),
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",
        local_files_only=True,
    )
    torch.cuda.synchronize()
    report(engine="qwen", load_seconds=round(time.perf_counter() - started, 3))
    for name, description in (
        ("qwen-masculina", "An adult male voice with a warm, clear medium-low timbre."),
        ("qwen-feminina", "An adult female voice with a warm, clear medium timbre."),
    ):
        torch.manual_seed(123)
        torch.cuda.reset_peak_memory_stats()
        started = time.perf_counter()
        wavs, sample_rate = model.generate_voice_design(
            text=args.text,
            language="Portuguese",
            instruct=(
                description
                + " Speak native European Portuguese from Portugal, with a Lisbon accent, "
                "natural connected speech, appropriate European Portuguese vowel reduction, "
                "and relaxed conversational rhythm. Friendly, fluid and matter-of-fact."
            ),
            max_new_tokens=384,
        )
        torch.cuda.synchronize()
        seconds = time.perf_counter() - started
        target = args.output / (name + ".wav")
        sf.write(target, wavs[0], sample_rate)
        report(
            engine="qwen", file=str(target), seconds=round(seconds, 3),
            audio_seconds=round(len(wavs[0]) / sample_rate, 3),
            peak_gpu_mib=round(torch.cuda.max_memory_allocated() / 1024**2),
        )


async def edge(args):
    import edge_tts

    voices = await asyncio.wait_for(edge_tts.list_voices(), timeout=30)
    available = {voice["ShortName"] for voice in voices}
    for voice in ("pt-PT-DuarteNeural", "pt-PT-RaquelNeural"):
        if voice not in available:
            report(engine="edge", voice=voice, error="Not in current service catalogue")
            continue
        target = args.output / (voice + ".mp3")
        started = time.perf_counter()
        first_audio = None
        with target.open("wb") as output:
            async def receive():
                nonlocal first_audio
                async for chunk in edge_tts.Communicate(args.text, voice).stream():
                    if chunk["type"] == "audio":
                        if first_audio is None:
                            first_audio = time.perf_counter() - started
                        output.write(chunk["data"])

            await asyncio.wait_for(receive(), timeout=60)
        report(
            engine="edge", file=str(target),
            first_audio_seconds=round(first_audio, 3) if first_audio else None,
            seconds=round(time.perf_counter() - started, 3),
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, choices=("qwen", "edge"))
    parser.add_argument("--model", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--text", default=TEXT)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if args.engine == "qwen":
        qwen(args)
    else:
        asyncio.run(edge(args))


if __name__ == "__main__":
    main()
