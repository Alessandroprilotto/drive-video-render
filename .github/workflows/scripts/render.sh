#!/usr/bin/env bash
# Usage: scripts/render.sh <INPUT_DIR> <OUTPUT_DIR>
set -euo pipefail

IN="${1:-$GITHUB_WORKSPACE/assets}"
OUT="${2:-$GITHUB_WORKSPACE/out}"
mkdir -p "$OUT"

LOG="$OUT/render.log"
exec > >(tee -a "$LOG") 2>&1

echo "== Start render =="
echo "Input:  $IN"
echo "Output: $OUT"

# ------- Helpers -------
# ------- Helpers -------
find_one() {
  local base="$1"
  shopt -s nullglob nocaseglob
  # Accetta QUALSIASI estensione (foto_1.*, audio_1.*)
  local cand=( "$IN/${base}".* )
  for f in "${cand[@]}"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

dur_secs() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" | awk '{printf "%.3f\n", $1+0}'
}

WIDTH=1080
HEIGHT=1920
FPS=30

BG="$(find_one bg || true)"
USE_BG=0
[[ -n "${BG:-}" ]] && { echo "• Trovata bg: $BG"; USE_BG=1; }

# ------- Effetti con movimento (zoom/pan) su OGNI clip -------
effect_for_index() {
  local i="$1" frames="$2"
  case "$i" in
    1) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0012*on\,1.25):x=min((iw-ow)*on/$frames,(iw-ow)/4):y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    2) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0008*on\,1.18):x=(iw-ow)*(1-on/$frames):y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    3) echo "[0:v]scale=1400:-2,zoompan=z=max(1.0\,1.22-0.0010*on):x=iw/2-(iw/zoom/2):y=min((ih-oh)*on/$frames,(ih-oh)/5):d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    4) echo "[0:v]scale=1400:-2,zoompan=z=1.0:x=(iw-ow)*on/$frames:y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    5) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0010*on\,1.20):x=(iw-ow)*(1-on/$frames):y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    6) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0015*on\,1.30):x=iw/2-(iw/zoom/2):y=ih/2-(ih/zoom/2):d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    *) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0010*on\,1.20):x=iw/2-(iw/zoom/2):y=ih/2-(ih/zoom/2):d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
  esac
}

# ------- Genera scene 1..6 -------
SCENES_BUILT=()
for i in 1 2 3 4 5 6; do
  IMG="$(find_one "foto_${i}")" || { echo "⚠️  Manca foto_${i}"; continue; }
  AUD="$(find_one "audio_${i}")" || { echo "⚠️  Manca audio_${i}"; continue; }

  ADUR="$(dur_secs "$AUD")"
  VDIR=$(python3 - <<'PY'
d=float("$ADUR")+0.7
print(f"{d:.3f}")
PY
)
  FRAMES=$(python3 - <<'PY'
import math
print(int(round($VDIR*$FPS)))
PY
)

  FX="$(effect_for_index "$i" "$FRAMES")"
  OUTFILE="$OUT/scene_${i}.mp4"

  echo "🎬 Scene $i | IMG=$(basename "$IMG") | AUD=$(basename "$AUD") | ~${VDIR}s"

  if [[ $USE_BG -eq 1 ]]; then
    ffmpeg -y -i "$AUD" -i "$BG" \
      -filter_complex "[0:a]volume=1.0[a0];[1:a]volume=0.25[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[aout]" \
      -map "[aout]" -c:a aac -b:a 192k "$OUT/mix_${i}.m4a"
    AUD_IN="$OUT/mix_${i}.m4a"
  else
    AUD_IN="$AUD"
  fi

  ffmpeg -y -loop 1 -i "$IMG" -i "$AUD_IN" -t "$VDIR" \
    -filter_complex "$FX" \
    -map "[v]" -map 1:a \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -r $FPS \
    -c:a aac -b:a 192k -shortest "$OUTFILE"

  SCENES_BUILT+=("$OUTFILE")
done

# ------- Concat finale -------
if [[ ${#SCENES_BUILT[@]} -eq 0 ]]; then
  echo "❌ Nessuna scena generata. Controlla nomi file (foto_1..6, audio_1..6)."
  exit 1
fi

LIST="$OUT/_list.txt"
: > "$LIST"
for f in "${SCENES_BUILT[@]}"; do
  echo "file '$f'" >> "$LIST"
done

ffmpeg -y -f concat -safe 0 -i "$LIST" \
  -c:v libx264 -pix_fmt yuv420p -r $FPS \
  -c:a aac -b:a 192k "$OUT/final.mp4"

echo "✅ Fatto. Output: $OUT/final.mp4"
