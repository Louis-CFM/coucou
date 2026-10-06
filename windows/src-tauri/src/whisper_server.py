import sys
import json
import warnings

warnings.filterwarnings("ignore")
sys.stdout.reconfigure(encoding="utf-8")

import torch
import whisper

# Biggest model first: it is loaded once, so only the first start pays for it.
model = None
for name in ("large-v3-turbo", "small", "base", "tiny"):
    try:
        model = whisper.load_model(name)
        break
    except Exception:
        continue

if model is None:
    print("ERROR:no whisper model could be loaded", flush=True)
    sys.exit(1)

USE_FP16 = torch.cuda.is_available()
CANDIDATES = ("id", "en")


def pick_language(path):
    """Indonesian or English only: free auto-detect often drifts to Malay or others."""
    audio = whisper.pad_or_trim(whisper.load_audio(path))
    mel = whisper.log_mel_spectrogram(audio, n_mels=model.dims.n_mels).to(model.device)
    if USE_FP16:
        mel = mel.half()
    _, probs = model.detect_language(mel)
    return max(CANDIDATES, key=lambda code: probs.get(code, 0.0))


print("READY", flush=True)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
        lang = req.get("lang") or None
        if lang == "auto":
            lang = pick_language(req["path"])
        res = model.transcribe(
            req["path"],
            language=lang,
            fp16=USE_FP16,
            verbose=False,
            condition_on_previous_text=False,
            temperature=0.0,
            initial_prompt=req.get("prompt") or None,
        )
        segments = res.get("segments") or []
        silent = bool(segments) and all(s.get("no_speech_prob", 0.0) > 0.6 for s in segments)
        text = "" if silent else res.get("text", "").strip()
        print("RESULT:" + text.replace("\r", " ").replace("\n", " "), flush=True)
    except Exception as e:
        print("ERROR:" + str(e).replace("\n", " "), flush=True)
