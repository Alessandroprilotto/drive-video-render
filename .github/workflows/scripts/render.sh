#!/usr/bin/env bash
# Usage: ./render.sh <INPUT_DIR> <OUTPUT_DIR>
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
find_one() {
  local base="$1"
  shopt -s nullglob nocaseglob
  local noext="$IN/${base}"
  if [[ -f "$noext" ]]; then echo "$noext"; return 0; fi
  local cand=( "$IN/${base}".* )
  for f in "${cand[@]}"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# Musica globale
find_music() {
  shopt -s nullglob nocaseglob
  local cand=(
    "$IN/music".*
    "$IN/song".*
    "$IN/bgmusic".*
    "$IN/bg_music".*
    "$IN/soundtrack".*
    "$IN/"*ciao*".mp3"
    "$IN/"*music*".mp3"
  )
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

# ------- Sottotitoli -------
SUBS=1
AUTO_STT=1
export FAST_WHISPER_MODEL="${FAST_WHISPER_MODEL:-small}"

FONTS_DIR="$IN/fonts"
STYLE_FONT="Montserrat ExtraBold"

F_SIZE=200
OUTLINE=6
SHADOW=0
MARGIN_V=500

make_ass_word_by_word() {
  local json="$1" ass_out="$2"
  python3 - <<PY
import json, pathlib
W,H = ${WIDTH}, ${HEIGHT}
FONT="${STYLE_FONT}"
SIZE=${F_SIZE}; OUTL=${OUTLINE}; SH=${SHADOW}; MARG=${MARGIN_V}

def ts(t):
    t=max(0.0,float(t)); h=int(t//3600); t-=h*3600
    m=int(t//60); t-=m*60; s=int(t); cs=int(round((t-s)*100))
    return f"{h:01d}:{m:02d}:{s:02d}.{cs:02d}"

PRIMARY   = "&H00FFFFFF"
SECONDARY = "&H0000FFFF"
OUTLINEC  = "&H00000000"
BACK      = "&H00000000"

with open("${json}","r",encoding="utf-8") as f:
    raw=json.load(f)

words=[]
for w in raw:
    txt=str(w.get("text","")).strip()
    if not txt: continue
    try:
        st=float(w["start"]); en=float(w["end"])
    except:
        continue
    if en<=st: en=st+0.01
    txt=txt.replace("{","(").replace("}",")").upper()
    words.append((st,en,txt))
words.sort(key=lambda x:x[0])

ass=[
"[Script Info]","ScriptType: v4.00+",
f"PlayResX: {W}",f"PlayResY: {H}","",
"[V4+ Styles]",
"Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
"Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
"Alignment, MarginL, MarginR, MarginV, Encoding",
f"Style: TikTok,{FONT},{SIZE},{PRIMARY},{SECONDARY},{OUTLINEC},{BACK},-1,0,0,0,100,100,0,0,1,{OUTL},{SH},2,60,60,{MARG},1",
"",
"[Events]","Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
]
for st,en,txt in words:
    ass.append(f"Dialogue: 0,{ts(st)},{ts(en)},TikTok,,0,0,0,,{txt}")

pathlib.Path("${ass_out}").write_text("\n".join(ass), encoding="utf-8")
print(f"Wrote ${ass_out}")
PY
}

gen_words_from_audio() {
  local audio="$1" out_json="$2"
  python3 - <<PY
import sys, json, os
audio = "${audio}"
out_json = "${out_json}"
model_size = os.getenv("FAST_WHISPER_MODEL","small")
try:
    from faster_whisper import WhisperModel
except Exception as e:
    print("⚠️  faster-whisper non installato:", e)
    sys.exit(2)

model = WhisperModel(model_size, device="cpu", compute_type="int8")
segments, _ = model.transcribe(audio, word_timestamps=True, vad_filter=True,
                               vad_parameters=dict(min_silence_duration_ms=200))
words=[]
for seg in segments:
    if not getattr(seg, "words", None):
        continue
    for w in seg.words:
        if not w.word:
            continue
        st = float(w.start if w.start is not None else seg.start)
        en = float(w.end   if w.end   is not None else st+0.01)
        words.append({"text": w.word.strip(), "start": max(0.0, st), "end": max(en, st+0.01)})
os.makedirs(os.path.dirname(out_json), exist_ok=True)
with open(out_json,"w",encoding="utf-8") as f: json.dump(words,f,ensure_ascii=False)
print(f"🧠 Creato {out_json} con {len(words)} parole")
PY
}

BG="$(find_one "bg" 2>/dev/null || true)"
USE_BG=0
[[ -n "${BG:-}" ]] && { echo "• Trovata bg: $BG"; USE_BG=1; }

effect_for_index() {
  local i="$1" frames="$2"
  case "$i" in
    1) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0012*on\,1.25):x=min((iw-ow)*on/$frames\,(iw-ow)/4):y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    2) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0008*on\,1.18):x=(iw-ow)*(1-on/$frames):y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    3) echo "[0:v]scale=1400:-2,zoompan=z=max(1.0\,1.22-0.0010*on):x=iw/2-(iw/zoom/2):y=min((ih-oh)*on/$frames\,(ih-oh)/5):d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    4) echo "[0:v]scale=1400:-2,zoompan=z=1.0:x=(iw-ow)*on/$frames:y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    5) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0010*on\,1.20):x=(iw-ow)*(1-on/$frames):y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    6) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0015*on\,1.30):x=iw/2-(iw/zoom/2):y=ih/2-(ih/zoom/2):d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    *) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0010*on\,1.20):x=iw/2-(iw/zoom/2):y=ih/2-(ih/zoom/2):d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
  esac
}

SCENES_BUILT=()
fontsdir_opt=""
if [[ -d "$FONTS_DIR" ]]; then
  fontsdir_opt=":fontsdir='${FONTS_DIR}'"
fi

for i in 1 2 3 4 5 6; do
  IMG="$(find_one "foto_${i}")"  || { echo "⚠️  Manca foto_${i}";  continue; }
  AUD="$(find_one "audio_${i}")" || { echo "⚠️  Manca audio_${i}"; continue; }

  ADUR="$(dur_secs "$AUD")"
  VDIR=$(python3 - <<PY
d=float("${ADUR}")+0.7
print(f"{d:.3f}")
PY
)
  FRAMES=$(python3 - <<PY
import math
VDIR=float("${VDIR}")
FPS=int("${FPS}")
print(int(round(VDIR*FPS)))
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

  CAP_JSON="$IN/words_${i}.json"
  CAP_ASS="$OUT/captions_${i}.ass"
  HAVE_CAP=0

  if [[ $SUBS -eq 1 && ! -f "$CAP_JSON" && $AUTO_STT -eq 1 ]]; then
    echo "🧠 Estraggo parole dall'audio per la scena $i..."
    gen_words_from_audio "$AUD" "$CAP_JSON" || true
  fi

  if [[ $SUBS -eq 1 && -f "$CAP_JSON" ]]; then
    echo "📝 Sottotitoli: uso $(basename "$CAP_JSON")"
    make_ass_word_by_word "$CAP_JSON" "$CAP_ASS" && HAVE_CAP=1
  fi

  if [[ $HAVE_CAP -eq 1 ]]; then
    ffmpeg -y -loop 1 -i "$IMG" -i "$AUD_IN" -t "$VDIR" \
      -filter_complex "$FX;[v]subtitles='${CAP_ASS}'${fontsdir_opt}[vf]" \
      -map "[vf]" -map 1:a \
      -c:v libx264 -preset veryfast -pix_fmt yuv420p -r $FPS \
      -c:a aac -b:a 192k -shortest "$OUTFILE"
  else
    ffmpeg -y -loop 1 -i "$IMG" -i "$AUD_IN" -t "$VDIR" \
      -filter_complex "$FX" \
      -map "[v]" -map 1:a \
      -c:v libx264 -preset veryfast -pix_fmt yuv420p -r $FPS \
      -c:a aac -b:a 192k -shortest "$OUTFILE"
  fi

  SCENES_BUILT+=("$OUTFILE")
done

if [[ ${#SCENES_BUILT[@]} -eq 0 ]]; then
  echo "❌ Nessuna scena generata."; exit 1
fi

LIST="$OUT/_list.txt"
: > "$LIST"
for f in "${SCENES_BUILT[@]}"; do
  echo "file '$f'" >> "$LIST"
done

ffmpeg -y -f concat -safe 0 -i "$LIST" \
  -c:v libx264 -pix_fmt yuv420p -r $FPS \
  -c:a aac -b:a 192k "$OUT/final.mp4"

# ------- Musica globale: ducking + limiter in un'unica traccia -------
MUSIC="$(find_music || true)"
if [[ -n "${MUSIC:-}" ]]; then
  echo "🎵 Musica globale trovata: $(basename "$MUSIC")"
  TDUR="$(dur_secs "$OUT/final.mp4")"

  ffmpeg -y -stream_loop -1 -i "$MUSIC" -t "$TDUR" -c:a aac -b:a 192k "$OUT/music_loop.m4a"

  NARR_VOL=${NARR_VOL:-1.00}
  MUSIC_VOL=${MUSIC_VOL:-0.30}

  FC="$OUT/fc_audio.txt"
  cat > "$FC" <<'EOF'
[0:a]aformat=channel_layouts=stereo,pan=stereo|c0=c0|c1=c0,volume=NARRVOL[SVOX];
[1:a]aformat=channel_layouts=stereo,volume=MUSVOL[SMUS];
[SMUS][SVOX]sidechaincompress=threshold=0.08:ratio=6:attack=5:release=250:makeup=1[SDUCK];
[SDUCK][SVOX]amix=inputs=2:duration=first:dropout_transition=2[SMIX];
[SMIX]alimiter=limit=0.95:level=disabled[SOUT]
EOF
  sed -i "s/NARRVOL/${NARR_VOL}/g; s/MUSVOL/${MUSIC_VOL}/g" "$FC"

  ffmpeg -y \
    -i "$OUT/final.mp4" \
    -i "$OUT/music_loop.m4a" \
    -filter_complex_script "$FC" \
    -map 0:v:0 -c:v copy \
    -map "[SOUT]" -c:a aac -b:a 192k -ac 2 -shortest \
    "$OUT/__final_with_bgm.mp4"

  mv -f "$OUT/__final_with_bgm.mp4" "$OUT/final.mp4"
  echo "🎧 Mix completo (voce + musica ducked) in una sola traccia stereo."
else
  echo "ℹ️ Nessuna musica globale trovata."
fi

echo "✅ Fatto. Output: $OUT/final.mp4"
