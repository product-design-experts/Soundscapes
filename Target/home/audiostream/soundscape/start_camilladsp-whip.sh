#!/bin/bash

set -euo pipefail

# Capture more context on failures in pipelines and subshells.
shopt -s inherit_errexit 2>/dev/null || true

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable Variables
WHIP_CLIENT_BINARY="/home/audiostream/soundscape/simple-whip-client/whip-client"  # Adjust to your actual path
CAMILLA_CONFIG="/home/audiostream/soundscape/bandpass.yml"      # Adjust to your CamillaDSP config

# IVS token refresh settings (can be overridden via environment variables)
IVS_REGION="${IVS_REGION:-us-east-1}"
IVS_STAGE_ARN="${IVS_STAGE_ARN:-arn:aws:ivs:us-east-1:961809614400:stage/bL4M27zUnHGK}"
IVS_DURATION_MINUTES="${IVS_DURATION_MINUTES:-20160}"  # Max duration is 20160 (14 days)
IVS_USER_ID="${IVS_USER_ID:-}"

VENV_PY="$BASE_DIR/.venv/bin/python"
if [[ -x "$VENV_PY" ]]; then
  PYTHON="$VENV_PY"
else
  PYTHON="python3"
fi

# Load repo-local Sentry config for manual runs.
# Under systemd, audiostream.service also sets EnvironmentFile, but when you
# run this script directly from a shell you typically won't have those vars.
SENTRY_ENV_FILE="${SENTRY_ENV_FILE:-$BASE_DIR/sentry.env}"
if [[ -f "$SENTRY_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SENTRY_ENV_FILE"
  set +a
fi

# --- Sentry (optional) ---
# Configure via environment variables (recommended via systemd EnvironmentFile):
#   SENTRY_DSN, SENTRY_ENVIRONMENT, SENTRY_RELEASE
SENTRY_HELPER="$BASE_DIR/sentry_event.py"

# Device identifier for Sentry context (best-effort).
# /proc/device-tree values are often NUL-terminated; strip NULs.
DEVICE_ID=""
if [[ -r /proc/device-tree/serial-number ]]; then
  DEVICE_ID="$(tr -d '\0' </proc/device-tree/serial-number 2>/dev/null | tr -d '\r\n' || true)"
fi

sentry_send() {
  # Usage: sentry_send LEVEL MESSAGE [extra_kv...]
  sentry_send_attach "$1" "$2" "" "${@:3}"
}

sentry_send_attach() {
  # Usage: sentry_send_attach LEVEL MESSAGE ATTACH_PATH [extra_kv...]
  local level="$1"; shift
  local message="$1"; shift
  local attach_path="$1"; shift

  if [[ -z "${SENTRY_DSN:-}" ]]; then
    return 0
  fi
  if [[ ! -f "$SENTRY_HELPER" ]]; then
    return 0
  fi

  local args=("$SENTRY_HELPER" --level "$level" --message "$message")
  args+=(--tag "host=$(hostname -s 2>/dev/null || hostname)")
  args+=(--tag "service=audiostream")
  args+=(--tag "component=start_camilladsp-whip")

  # Standard additional data for all events.
  if [[ -n "${DEVICE_ID:-}" ]]; then
    args+=(--extra "device_id=$DEVICE_ID")
  fi
  if [[ -n "${LOG_DIR:-}" ]]; then
    args+=(--extra "log_dir=$LOG_DIR")
  fi

  if [[ -n "${attach_path:-}" && -f "$attach_path" ]]; then
    args+=(--attach "$attach_path")
  fi

  # Optional extras in k=v form.
  while [[ $# -gt 0 ]]; do
    args+=(--extra "$1")
    shift
  done

  "$PYTHON" "${args[@]}" || true
}

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

# Logs: keep a small on-device trail for incident context.
LOG_DIR="${LOG_DIR:-$TOKEN_DIR/logs}"
mkdir -p "$LOG_DIR"

CAMILLADSP_LOG="$LOG_DIR/camilladsp.log"
WHIP_LOG="$LOG_DIR/whip-client.log"
SCRIPT_LOG="$LOG_DIR/start_camilladsp-whip.log"

STOPPING=0

tail_file() {
  local file="$1"
  local lines="${2:-200}"
  [[ -f "$file" ]] || return 0
  tail -n "$lines" "$file" 2>/dev/null || true
}

write_tail_tmp() {
  local src="$1"
  local dest="$2"
  local lines="${3:-200}"
  tail_file "$src" "$lines" >"$dest" || true
}

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

log "LOG_DIR: $LOG_DIR"
log "CAMILLADSP_LOG: $CAMILLADSP_LOG"
log "WHIP_LOG: $WHIP_LOG"

# Mirror script logs to file (and still to journald).
exec > >(tee -a "$SCRIPT_LOG") 2> >(tee -a "$SCRIPT_LOG" >&2)

# Major lifecycle event: supervisor start.
sentry_send info "soundscape supervisor started" \
  "gst_debug=$GST_DEBUG" || true

on_error() {
  local rc=$?
  local line_no=${BASH_LINENO[0]:-}
  local cmd=${BASH_COMMAND:-"?"}
  log "ERROR: command failed (rc=$rc) at line $line_no: $cmd"

  local tmp
  tmp="$(mktemp "$LOG_DIR/soundscape-script-tail.XXXXXX.txt")" || tmp=""
  if [[ -n "$tmp" ]]; then
    write_tail_tmp "$SCRIPT_LOG" "$tmp" 200
  fi

  if [[ -n "$tmp" ]]; then
    sentry_send_attach error "start_camilladsp-whip.sh failed (rc=$rc)" "$tmp" \
      "where=bash" \
      "line=$line_no" \
      "command=$cmd" || true
    rm -f "$tmp" || true
  else
    sentry_send error "start_camilladsp-whip.sh failed (rc=$rc)" \
      "line=$line_no" \
      "command=$cmd" || true
  fi

  return "$rc"
}

trap on_error ERR

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
camilladsp "$CAMILLA_CONFIG" -s state.yml \
  > >(tee -a "$CAMILLADSP_LOG") \
  2> >(tee -a "$CAMILLADSP_LOG" >&2) &

CAMILLA_PID=$!
log "CamillaDSP PID: $CAMILLA_PID"

# Ensure we clean up on stop
cleanup() {
  local reason="${1:-signal}"
  STOPPING=1
  log "Shutting down… (reason=$reason)"

  # Major lifecycle event: supervisor stop.
  sentry_send info "soundscape supervisor stopping" \
    "reason=$reason" || true

  kill -TERM "$CAMILLA_PID" 2>/dev/null || true
  kill -TERM "$WHIP_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM

# Detect CamillaDSP exiting unexpectedly (e.g., config/device issues).
(
  wait "$CAMILLA_PID"
  rc=$?
  if (( STOPPING == 0 )); then
    log "CamillaDSP exited unexpectedly (rc=$rc)."
    sentry_send error "camilladsp exited unexpectedly" \
      "rc=$rc" || true
  else
    log "CamillaDSP exited during shutdown (rc=$rc)."
  fi
) &

# Reconnect loop for WHIP client (assumes it uses DOLBYIO_AUDIO_PIPE, DOLBYIO_WHIP_ENDPOINT & DOLBYIO_BEARER_TOKEN internally)
log "Starting WHIP client..."
WHIP_COMMAND="$WHIP_CLIENT_BINARY"

whip_fail_count=0

while true; do
  wait_for_net
  refresh_ivs_token_and_export
  log "Starting WHIP client…"

  # NOTE: We avoid piping the whole process so we keep the correct PID.
  # We capture both stdout/stderr to a file while still emitting to journald.
  "$WHIP_COMMAND" -l 4 \
    > >(tee -a "$WHIP_LOG") \
    2> >(tee -a "$WHIP_LOG" >&2) &
  WHIP_PID=$!
  log "WHIP client PID: $WHIP_PID"

  # Wait for the WHIP client only; if it exits, try again
  if ! wait "$WHIP_PID"; then
    rc=$?
    whip_fail_count=$((whip_fail_count+1))
    log "WHIP client exited with code $rc (fail_count=$whip_fail_count). Will retry shortly…"

    # Send a Sentry event for non-zero exits with the tail of the WHIP/GStreamer log.
    tmp="$(mktemp "$LOG_DIR/soundscape-whip-tail.XXXXXX.txt")" || tmp=""
    if [[ -n "$tmp" ]]; then
      write_tail_tmp "$WHIP_LOG" "$tmp" 250
      sentry_send_attach error "whip-client exited (rc=$rc)" "$tmp" \
        "where=whip-client" \
        "rc=$rc" \
        "fail_count=$whip_fail_count" \
        "gst_debug=$GST_DEBUG" || true
      rm -f "$tmp" || true
    else
      sentry_send error "whip-client exited (rc=$rc)" \
        "rc=$rc" \
        "fail_count=$whip_fail_count" \
        "gst_debug=$GST_DEBUG" || true
    fi

    # Escalate if we're flapping.
    if (( whip_fail_count >= 5 )); then
      sentry_send warning "whip-client repeatedly failing" "fail_count=$whip_fail_count" || true
      whip_fail_count=0
    fi
  else
    log "WHIP client exited cleanly. Restarting to maintain stream…"
    whip_fail_count=0
  fi

  sleep 2
done

