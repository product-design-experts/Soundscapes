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
  queue max-size-buffers=20 max-size-time=0 max-size-bytes=0 ! \
  audioconvert ! \
  opusenc ! \
  rtpopuspay ! \
  application/x-rtp,media=audio,encoding-name=OPUS,payload=111"

#export GST_DEBUG="*:2"
# Start CamillaDSP
echo "Starting CamillaDSP..."
camilladsp /home/audiostream/soundscape/bandpass.yml -s state.yml -v &

CAMILLA_PID=$!
echo "CamillaDSP PID: $CAMILLA_PID"

# Start WHIP client (assumes it uses DOLBYIO_AUDIO_PIPE, DOLBYIO_WHIP_ENDPOINT & DOLBYIO_BEARER_TOKEN internally)
echo "Starting WHIP client..."
WHIP_COMMAND="$WHIP_CLIENT_BINARY"


# Launch the whip client
eval "$WHIP_COMMAND -l 7" &

WHIP_PID=$!
echo "WHIP client PID: $WHIP_PID"

# Wait for background processes
wait $CAMILLA_PID $WHIP_PID
