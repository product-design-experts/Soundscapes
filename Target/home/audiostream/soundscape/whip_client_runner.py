#!/usr/bin/env python3

import json
import os
import sys
from pathlib import Path


def _env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value is not None and value != "" else default


def load_token(token_file: str) -> str:
    path = Path(token_file)
    if not path.exists():
        raise RuntimeError(f"Token file does not exist: {path}")
    try:
        meta = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Token file is not valid JSON: {path} ({e})")

    token = meta.get("token")
    if not token:
        raise RuntimeError(f"Token file missing 'token' field: {path}")
    return str(token)


def main() -> int:
    whip_client = _env(
        "WHIP_CLIENT_BINARY",
        "/home/audiostream/soundscape/simple-whip-client/whip-client",
    )
    log_level = _env("WHIP_CLIENT_LOG_LEVEL", "4")

    token_file = _env("IVS_TOKEN_FILE", "/run/audiostream/participant_token.json")
    token = load_token(token_file)

    os.environ["DOLBYIO_BEARER_TOKEN"] = token
    os.environ.setdefault("DOLBYIO_WHIP_ENDPOINT", "https://global.whip.live-video.net")

    os.environ.setdefault(
        "DOLBYIO_VIDEO_PIPE",
        "videotestsrc is-live=true pattern=black ! "
        "videoconvert ! x264enc tune=zerolatency bitrate=1000 ! "
        "rtph264pay ! application/x-rtp,media=video,encoding-name=H264,payload=97",
    )

    os.environ.setdefault(
        "DOLBYIO_AUDIO_PIPE",
        "alsasrc device=hw:Loopback,1,0 do-timestamp=true ! "
        "audio/x-raw,format=S16LE,rate=48000,channels=2,layout=interleaved ! "
        "identity sync=true ! "
        "queue leaky=downstream max-size-buffers=20 max-size-time=0 max-size-bytes=0 ! "
        "watchdog timeout=5000 ! "
        "audioconvert ! opusenc ! rtpopuspay ! "
        "application/x-rtp,media=audio,encoding-name=OPUS,payload=96",
    )

    argv = [whip_client, "-l", log_level]
    os.execvpe(whip_client, argv, os.environ)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f"whip_client_runner: ERROR: {e}", file=sys.stderr)
        raise SystemExit(2)
