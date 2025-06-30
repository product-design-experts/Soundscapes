#!/bin/bash

set -euo pipefail

# Configurable Variables
PIPE_PATH="/tmp/audio_pipe"
WHIP_CLIENT_BINARY="/home/audiostream/simple-whip-client/whip-client"  # Adjust to your actual path
CAMILLA_CONFIG="/home/audiostream/camilladsp.yml"      # Adjust to your CamillaDSP config

# Create named pipe
if [[ -p "$PIPE_PATH" ]]; then
  echo "Named pipe $PIPE_PATH already exists."
else
  echo "Creating named pipe at $PIPE_PATH"
  mkfifo "$PIPE_PATH"
fi

# Used for streaming to Dolby.io using WHIP.  Program will fail if not defined (including video pipe name)
export DOLBYIO_BEARER_TOKEN="baa23d532516f3000ebababf4f208f858e29cb2418ebc0aaca17b592eea0737a"
export DOLBYIO_WHIP_ENDPOINT="https://director.millicast.com/api/whip/RPI-Stream-1"
export DOLBYIO_VIDEO_PIPE=
#export DOLBYIO_AUDIO_PIPE="filesrc location=/tmp/audio_pipe ! \
#  audio/x-raw,format=S16LE,rate=44100,channels=2 ! \
#  audioconvert ! \
#  audioresample ! \
#  audio/x-raw,format=S16LE,rate=48000,channels=2 ! \
#  opusenc ! \
#  rtpopuspay ! \
#  application/x-rtp,media=audio,encoding-name=OPUS,payload=111"

export DOLBYIO_AUDIO_PIPE="filesrc location=/tmp/audio_pipe do-timestamp=true blocksize=8192 ! \
  audio/x-raw,format=S32LE,rate=48000,channels=2,layout=interleaved ! \
  identity sync=true !
  queue !
  audioconvert ! \
  audioresample ! \
  opusenc ! \
  rtpopuspay ! \
  application/x-rtp,media=audio,encoding-name=OPUS,payload=111"

echo "Exported DOLBYIO_AUDIO_PIPE: $DOLBYIO_AUDIO_PIPE"

#export GST_DEBUG="*:2"

# Start CamillaDSP
echo "Starting CamillaDSP..."
camilladsp /home/audiostream/camilladsp.yml -s state.yml -v &

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
