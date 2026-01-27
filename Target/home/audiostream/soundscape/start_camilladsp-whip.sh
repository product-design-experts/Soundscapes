#!/bin/bash

set -euo pipefail

# Configurable Variables
WHIP_CLIENT_BINARY="/home/audiostream/soundscape/simple-whip-client/whip-client"  # Adjust to your actual path
CAMILLA_CONFIG="/home/audiostream/soundscape/bandpass.yml"      # Adjust to your CamillaDSP config

# Enable Alsa Loopback
sudo modprobe snd-aloop

# Used for streaming to Dolby.io using WHIP.  Program will fail if not defined (including video pipe name)
export DOLBYIO_BEARER_TOKEN="eyJhbGciOiJLTVMiLCJ0eXAiOiJKV1QifQ.eyJleHAiOjE3Njk2MjA3NTksImlhdCI6MTc2ODQxMTE1OSwianRpIjoiaVFSS1pqMnk5SVc0IiwicmVzb3VyY2UiOiJhcm46YXdzOml2czp1cy1lYXN0LTE6OTYxODA5NjE0NDAwOnN0YWdlL2JMNE0yN3pVbkhHSyIsInRvcGljIjoiYkw0TTI3elVuSEdLIiwiZXZlbnRzX3VybCI6IndzczovL2dsb2JhbC5ldmVudHMubGl2ZS12aWRlby5uZXQiLCJ3aGlwX3VybCI6Imh0dHBzOi8vZmU2NDZmYjViYzZjLmdsb2JhbC1ibS53aGlwLmxpdmUtdmlkZW8ubmV0IiwidXNlcl9pZCI6IlJQSS0xLVRva2VuIiwiY2FwYWJpbGl0aWVzIjp7ImFsbG93X3B1Ymxpc2giOnRydWUsImFsbG93X3N1YnNjcmliZSI6dHJ1ZX0sInZlcnNpb24iOiIwLjAifQ.MGUCMA-weHc6CSdV3XEFAE3Bn1vW8DZHsu32RRLMfkh_w2QskXf9k3mXSAVcTYnz-zjfyAIxAOxw6lmg527uRwCRcdpfcdkWRbeYPbWMqF8FqDFhvRXeRbWUnbtC-J5QUIHcK5yD7A"
#export DOLBYIO_WHIP_ENDPOINT="https://fe646fb5bc6c.global-bm.whip.live-video.net"
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

export GST_DEBUG="*:4,rtp*:1"
log "GST_DEBUG: $GST_DEBUG"

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

