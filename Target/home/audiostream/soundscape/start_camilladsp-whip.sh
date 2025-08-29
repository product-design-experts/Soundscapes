#!/bin/bash

set -euo pipefail

# Configurable Variables
WHIP_CLIENT_BINARY="/home/audiostream/soundscape/simple-whip-client/whip-client"  # Adjust to your actual path
CAMILLA_CONFIG="/home/audiostream/soundscape/bandpass.yml"      # Adjust to your CamillaDSP config

# Enable Alsa Loopback
sudo modprobe snd-aloop

# Used for streaming to Dolby.io using WHIP.  Program will fail if not defined (including video pipe name)
export DOLBYIO_BEARER_TOKEN="baa23d532516f3000ebababf4f208f858e29cb2418ebc0aaca17b592eea0737a"
export DOLBYIO_WHIP_ENDPOINT="https://director.millicast.com/api/whip/RPI-Stream-1"
export DOLBYIO_VIDEO_PIPE=

export DOLBYIO_AUDIO_PIPE="alsasrc device=hw:Loopback,1,0 do-timestamp=true ! \
  audio/x-raw,format=S16LE,rate=48000,channels=2,layout=interleaved ! \
  identity sync=true ! \
  queue leaky=downstream max-size-buffers=20 max-size-time=0 max-size-bytes=0 ! \
  watchdog timeout=5000 ! \
  audioconvert ! \
  opusenc ! \
  rtpopuspay ! \
  application/x-rtp,media=audio,encoding-name=OPUS,payload=111"

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

export GST_DEBUG="*:2"
log "GST_DEBUG: $GST_DEBUG"

# Start CamillaDSP
log "Starting CamillaDSP..."
camilladsp /home/audiostream/soundscape/bandpass.yml -s state.yml -v &

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
  log "Starting WHIP client…"
  eval "$WHIP_COMMAND -l 7" &
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

