#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable Variables
WHIP_CLIENT_BINARY="/home/audiostream/soundscape/simple-whip-client/whip-client"  # Adjust to your actual path
CAMILLA_CONFIG="/home/audiostream/soundscape/bandpass.yml"      # Adjust to your CamillaDSP config

# IVS token refresh settings (can be overridden via environment variables)
IVS_REGION="${IVS_REGION:-us-east-1}"
IVS_STAGE_ARN="${IVS_STAGE_ARN:-arn:aws:ivs:us-east-1:961809614400:stage/bL4M27zUnHGK}"
IVS_DURATION_MINUTES="${IVS_DURATION_MINUTES:-720}"
IVS_USER_ID="${IVS_USER_ID:-}"

VENV_PY="$BASE_DIR/.venv/bin/python"
if [[ -x "$VENV_PY" ]]; then
  PYTHON="$VENV_PY"
else
  PYTHON="python3"
fi

# AWS SDK / boto3 credential configuration (overrideable).
AWS_CONFIG_FILE_DEFAULT="$BASE_DIR/.aws/config"
AWS_SHARED_CREDENTIALS_FILE_DEFAULT="$BASE_DIR/.aws/credentials"

export AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$AWS_CONFIG_FILE_DEFAULT}"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$AWS_SHARED_CREDENTIALS_FILE_DEFAULT}"

# Optional: set AWS_PROFILE externally if you use named profiles.
# export AWS_PROFILE="${AWS_PROFILE:-default}"

# Prefer /run/audiostream when available; otherwise fall back to a user-writable runtime dir.
DEFAULT_TOKEN_DIR="/tmp/audiostream"
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  FALLBACK_TOKEN_DIR="$XDG_RUNTIME_DIR/audiostream"
else
  FALLBACK_TOKEN_DIR="/tmp/audiostream"
fi

TOKEN_DIR="$DEFAULT_TOKEN_DIR"
if [[ ! -d "$TOKEN_DIR" || ! -w "$TOKEN_DIR" ]]; then
  TOKEN_DIR="$FALLBACK_TOKEN_DIR"
fi

IVS_TOKEN_FILE="${IVS_TOKEN_FILE:-$TOKEN_DIR/participant_token.json}"

refresh_ivs_token_and_export() {
  mkdir -p "$(dirname "$IVS_TOKEN_FILE")"

  log "Refreshing IVS participant token (if needed)…"
  if [[ -n "$IVS_USER_ID" ]]; then
    "$PYTHON" "$BASE_DIR/refresh_ivs_token.py" \
      --stage-arn "$IVS_STAGE_ARN" \
      --token-file "$IVS_TOKEN_FILE" \
      --duration-minutes "$IVS_DURATION_MINUTES" \
      --region "$IVS_REGION" \
      --user-id "$IVS_USER_ID" \
      >/dev/null
  else
    "$PYTHON" "$BASE_DIR/refresh_ivs_token.py" \
      --stage-arn "$IVS_STAGE_ARN" \
      --token-file "$IVS_TOKEN_FILE" \
      --duration-minutes "$IVS_DURATION_MINUTES" \
      --region "$IVS_REGION" \
      >/dev/null
  fi

  # Initialize the legacy env var used by the WHIP client.
  DOLBYIO_BEARER_TOKEN="$("$PYTHON" - "$IVS_TOKEN_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    meta = json.load(f)
token = meta.get('token')
if not token:
    raise SystemExit('Token file missing token field')
print(token)
PY
 )"

  if [[ -z "${DOLBYIO_BEARER_TOKEN:-}" ]]; then
    log "ERROR: DOLBYIO_BEARER_TOKEN is empty after refresh."
    return 1
  fi

  export DOLBYIO_BEARER_TOKEN
  log "DOLBYIO_BEARER_TOKEN loaded from $IVS_TOKEN_FILE"
}

# Enable Alsa Loopback
sudo modprobe snd-aloop

# Used for streaming to Dolby.io using WHIP. Program will fail if not defined.
# This is initialized from AWS IVS via refresh_ivs_token.py at runtime.
export DOLBYIO_BEARER_TOKEN=""
export DOLBYIO_WHIP_ENDPOINT="https://global.whip.live-video.net"
export DOLBYIO_VIDEO_PIPE="videotestsrc is-live=true pattern=black ! \
      videoconvert ! x264enc tune=zerolatency bitrate=1000 ! \
      rtph264pay ! \
      application/x-rtp,media=video,encoding-name=H264,payload=97"

export DOLBYIO_AUDIO_PIPE="alsasrc device=hw:Loopback,1,0 do-timestamp=true ! \
  audio/x-raw,format=S16LE,rate=48000,channels=2,layout=interleaved ! \
  identity sync=true ! \
  queue leaky=downstream max-size-buffers=20 max-size-time=0 max-size-bytes=0 ! \
  watchdog timeout=5000 ! \
  audioconvert ! \
  opusenc ! \
  rtpopuspay ! \
  application/x-rtp,media=audio,encoding-name=OPUS,payload=96"

# --- helpers for logging and connectivity ---
log() { printf "[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n" -1 "$*"; }

wait_for_net() {
  local tries=0
  while ! ping -c1 -w1 8.8.8.8 >/dev/null 2>&1; do
    tries=$((tries+1))
    local sleep_s=$(( tries < 10 ? tries : 10 ))
    log "No Internet yet (attempt $tries). Retrying in ${sleep_s}s…"
    sleep "$sleep_s"
  done
}

export GST_DEBUG="*:1,rtp*:1"
log "GST_DEBUG: $GST_DEBUG"
log "AWS_CONFIG_FILE: $AWS_CONFIG_FILE"
log "AWS_SHARED_CREDENTIALS_FILE: $AWS_SHARED_CREDENTIALS_FILE"

# If CamillaDSP is already running (e.g., from a previous crash/restart), stop it first.
existing_camilla_pids="$(pgrep -x camilladsp 2>/dev/null || true)"
if [[ -n "$existing_camilla_pids" ]]; then
  log "Found existing camilladsp process(es): $existing_camilla_pids. Stopping them…"
  # Try graceful stop first.
  kill -TERM $existing_camilla_pids 2>/dev/null || true
  for _ in {1..20}; do
    if ! pgrep -x camilladsp >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  if pgrep -x camilladsp >/dev/null 2>&1; then
    log "camilladsp still running after timeout; sending SIGKILL…"
    pkill -KILL -x camilladsp 2>/dev/null || true
  fi
fi

# Start CamillaDSP
log "Starting CamillaDSP..."
camilladsp /home/audiostream/soundscape/bandpass.yml -s state.yml &

CAMILLA_PID=$!
log "CamillaDSP PID: $CAMILLA_PID"

# Ensure we clean up on stop
cleanup() {
  log "Shutting down…"
  kill -TERM "$CAMILLA_PID" 2>/dev/null || true
  kill -TERM "$WHIP_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup INT TERM

# Reconnect loop for WHIP client (assumes it uses DOLBYIO_AUDIO_PIPE, DOLBYIO_WHIP_ENDPOINT & DOLBYIO_BEARER_TOKEN internally)
log "Starting WHIP client..."
WHIP_COMMAND="$WHIP_CLIENT_BINARY"

while true; do
  wait_for_net
  refresh_ivs_token_and_export
  log "Starting WHIP client…"
  eval "$WHIP_COMMAND -l 4" &
  WHIP_PID=$!
  log "WHIP client PID: $WHIP_PID"

  # Wait for the WHIP client only; if it exits, try again
  if ! wait "$WHIP_PID"; then
    rc=$?
    log "WHIP client exited with code $rc. Will retry shortly…"
  else
    log "WHIP client exited cleanly. Restarting to maintain stream…"
  fi

  sleep 2
done

