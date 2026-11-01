#!/bin/bash
# Exactness check for the continuous-MP3 stream decoder (macOS only, no simulator).
# Gets a real streamed MP3 from the speech relay (127.0.0.1:1237, the app's request),
# decodes it with ffmpeg as the reference, compiles ios/Runner/SpeechMp3Stream.swift
# unchanged with the test in scripts/mp3_stream_exactness/, and runs it.
# Usage: scripts/mp3-stream-exactness.sh [text]    (needs ~/srv/lan-relay/lan-proxy.token)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FFMPEG="${FFMPEG:-$HOME/llm-tools/tts-venv/bin/ffmpeg-real}"
WORK="$(mktemp -d)"
TEXT="${1:-This is a test of the streaming speech path. It has two sentences, so the stream carries a little more audio.}"
TOKEN="$(cat "$HOME/srv/lan-relay/lan-proxy.token")"
BODY="$(python3 -c 'import json,sys; print(json.dumps({"model":"tts-1","input":sys.argv[1],"voice":"bobby","response_format":"mp3","stream":True,"streaming_interval":0.5}))' "$TEXT")"
curl -s -m 60 -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: audio/mpeg' \
  -o "$WORK/s.mp3" http://127.0.0.1:1237/v1/audio/speech -d "$BODY"
"$FFMPEG" -v error -y -i "$WORK/s.mp3" -f f32le -ac 1 "$WORK/ref.f32"
swiftc -O -o "$WORK/exact" "$HERE/scripts/mp3_stream_exactness/main.swift" "$HERE/ios/Runner/SpeechMp3Stream.swift"
"$WORK/exact" "$WORK/s.mp3" "$WORK/ref.f32" 24000 ${SEEDS:-200}
rm -rf "$WORK"
