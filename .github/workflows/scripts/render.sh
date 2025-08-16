#!/usr/bin/env bash
# Usage: ./render.sh <INPUT_DIR>
set -euo pipefail

# Cartella input da argomento o default a $GITHUB_WORKSPACE/assets
WS="${GITHUB_WORKSPACE:-$PWD}"
IN="${1:-$WS/assets}"

# Output nella stessa cartella degli input
OUT="$IN"
mkdir -p "$OUT"

LOG="$OUT/render.log"
exec > >(tee -a "$LOG") 2>&1

echo "== Start render =="
echo "Input/Output: $IN"

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

dur_secs() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" | awk '{printf "%.3f\n", $1+0}'
}

WIDTH=1080
HEIGHT=1920
FPS=30

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
PY
}

gen_words_from_audio() {
  local audio="$1" out_json="$2"
  python3 - <<PY
import json, os
audio = "${audio}"
out_json = "${out_json}"
model_size = os.getenv("FAST_WHISPER_MODEL","small")
from faster_whisper import WhisperModel
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
with open(out_json,"w",encoding="utf-8") as f:
    import json as J; J.dump(words,f,ensure_ascii=False)
PY
}

effect_for_index() {
  local i="$1" frames="$2"
  case "$i" in
    1) echo "[0:v]scale=1400:-2,zoompan=z=min(1.0+0.0012*on\,1.25):x=min((iw-ow)*on/$frames\,(iw-ow)/4):y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
    *) echo "[0:v]scale=1400:-2,zoompan=z=1.0:x=(iw-ow)/2:y=(ih-oh)/2:d=${frames}:s=${WIDTH}x${HEIGHT},fps=${FPS}[v]";;
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

  CAP_JSON="$IN/words_${i}.json"
  CAP_ASS="$OUT/captions_${i}.ass"
  HAVE_CAP=0

  if [[ $SUBS -eq 1 && ! -f "$CAP_JSON" && $AUTO_STT -eq 1 ]]; then
    gen_words_from_audio "$AUD" "$CAP_JSON" || true
  fi
  if [[ $SUBS -eq 1 && -f "$CAP_JSON" ]]; then
    make_ass_word_by_word "$CAP_JSON" "$CAP_ASS" && HAVE_CAP=1
  fi

  if [[ $HAVE_CAP -eq 1 ]]; then
    ffmpeg -y -loop 1 -i "$IMG" -i "$AUD" -t "$VDIR" \
      -filter_complex "$FX;[v]subtitles='${CAP_ASS}'${fontsdir_opt}[vf]" \
      -map "[vf]" -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p -r $FPS \
      -c:a aac -b:a 192k -shortest "$OUTFILE"
  else
    ffmpeg -y -loop 1 -i "$IMG" -i "$AUD" -t "$VDIR" \
      -filter_complex "$FX" \
      -map "[v]" -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p -r $FPS \
      -c:a aac -b:a 192k -shortest "$OUTFILE"
  fi

  SCENES_BUILT+=("$OUTFILE")
done

LIST="$OUT/_list.txt"
: > "$LIST"
for f in "${SCENES_BUILT[@]}"; do
  echo "file '$f'" >> "$LIST"
done

# Final video
ffmpeg -y -f concat -safe 0 -i "$LIST" -c:v libx264 -pix_fmt yuv420p -r $FPS \
  -c:a aac -b:a 192k "$OUT/final.mp4"

echo "✅ Video pronto: $OUT/final.mp4"

# --- Invio diretto al webhook n8n ---
WEBHOOK_URL="${N8N_WEBHOOK_URL:-https://digitale.app.n8n.cloud/webhook/ba7c7a08-7ba7-43cf-b4cb-7dc6b8a22ed2}"
echo "📤 Invio video a n8n..."
if ! curl -sS --retry 3 --fail -X POST \
  -F "file=@$OUT/final.mp4;type=video/mp4;filename=final.mp4" \
  "$WEBHOOK_URL?source=github&repo=${GITHUB_REPOSITORY:-local}&run_id=${GITHUB_RUN_ID:-0}"; then
  echo "⚠️  Invio a n8n fallito (proseguirò comunque)."
else
  echo "✅ Video inviato al webhook"
fi

# --- Copia compatibilità per altri step del workflow (se servono) ---
mkdir -p "$WS/out"
cp -f "$OUT/final.mp4" "$WS/out/final.mp4"
echo "📦 Copia compatibilità: $WS/out/final.mp4"
