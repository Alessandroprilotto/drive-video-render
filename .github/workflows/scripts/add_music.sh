#!/bin/bash
# Uso: add_music.sh <video_input> <musica_input> <video_output>
# Esempio: ./add_music.sh out/final.mp4 assets/music.mp3 out/final_with_music.mp4

set -euo pipefail

VIDEO_INPUT="$1"
MUSIC_INPUT="$2"
VIDEO_OUTPUT="$3"

if [ ! -f "$VIDEO_INPUT" ]; then
    echo "❌ Video di input non trovato: $VIDEO_INPUT"
    exit 1
fi

if [ ! -f "$MUSIC_INPUT" ]; then
    echo "❌ File musica non trovato: $MUSIC_INPUT"
    exit 1
fi

echo "🎵 Aggiungo musica di sottofondo a: $VIDEO_INPUT"
echo "   Musica: $MUSIC_INPUT"
echo "   Output: $VIDEO_OUTPUT"

# Volume voce = 1.0, volume musica = 0.3
ffmpeg -y -i "$VIDEO_INPUT" -i "$MUSIC_INPUT" \
  -filter_complex "[1:a]volume=0.3[a1];[0:a][a1]amix=inputs=2:duration=first:dropout_transition=3" \
  -c:v copy -c:a aac -b:a 192k \
  "$VIDEO_OUTPUT"

echo "✅ Musica aggiunta con successo: $VIDEO_OUTPUT"
