"""Private stdin -> MP3 bridge. edge-tts is installed in the app's own venv."""
import asyncio
import json
import sys

import edge_tts


async def main():
    request = json.load(sys.stdin)
    text = request["text"]
    if not isinstance(text, str) or not text.strip() or len(text) > 8000:
        raise ValueError("Invalid speech length")
    # The selected audition voice. No subscription credentials or API keys.
    async for chunk in edge_tts.Communicate(text, "pt-PT-RaquelNeural").stream():
        if chunk["type"] == "audio":
            sys.stdout.buffer.write(chunk["data"])
            sys.stdout.buffer.flush()


asyncio.run(asyncio.wait_for(main(), timeout=25))
