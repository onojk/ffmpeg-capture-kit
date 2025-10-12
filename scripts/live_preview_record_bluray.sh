#!/usr/bin/env bash
set -euo pipefail
VIDEO_DEV="${VIDEO_DEV:-/dev/video4}"
AUDIO_SRC="${AUDIO_SRC:-@DEFAULT_SOURCE@}"
IN_FMT="${IN_FMT:-mjpeg}"                 # mjpeg (lighter) or yuyv422 (steadier)
BLURAY_MODE="${BLURAY_MODE:-1}"           # 1 = optimize for BD playback
BR_WIDTH="${BR_WIDTH:-1280}"
BR_HEIGHT="${BR_HEIGHT:-720}"
BR_FPS="${BR_FPS:-24000/1001}"            # 23.976
DEINTERLACE="${DEINTERLACE:-auto}"        # auto|on|off
QUALITY="${QUALITY:-med}"                 # high|med|low
WINDOW_TITLE="${WINDOW_TITLE:-LivePreview}"
OUT_DIR="${OUT_DIR:-$HOME/Videos}"

mkdir -p "$OUT_DIR"
STAMP="$(date +'%Y%m%d_%H%M%S')"
OUT_MP4="$OUT_DIR/capture_${STAMP}.mp4"
PREVIEW_FIFO="/tmp/cap_preview_${STAMP}.ts"
RECORD_FIFO="/tmp/cap_record_${STAMP}.ts"

need(){ command -v "$1" &>/dev/null || { echo "Missing '$1' (sudo apt install $1)"; exit 1; }; }
need ffmpeg; need ffplay

case "$QUALITY" in
  high) CAP_PRESET="veryfast"; CAP_CRF=18 ;;
  med)  CAP_PRESET="veryfast"; CAP_CRF=22 ;;
  low)  CAP_PRESET="ultrafast"; CAP_CRF=28 ;;
  *)    CAP_PRESET="veryfast"; CAP_CRF=22 ;;
esac

if [[ "$BLURAY_MODE" == "1" ]]; then
  MAXRATE="${MAXRATE:-4M}"; BUFSIZE="${BUFSIZE:-8M}"
  A_BITRATE="${A_BITRATE:-128k}"
  case "$DEINTERLACE" in
    on)   DEINT="yadif=mode=0:parity=-1:deint=1," ;;
    off)  DEINT="" ;;
    auto) DEINT="" ;;
  esac
  SCALE_CHAIN="${DEINT}fps=${BR_FPS},scale=${BR_WIDTH}:${BR_HEIGHT}:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=${BR_WIDTH}:${BR_HEIGHT}:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"
  VID_ENC=(-c:v libx264 -preset "$CAP_PRESET" -tune zerolatency -crf "$CAP_CRF" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" -g 48 -bf 0 -pix_fmt yuv420p)
  AUD_ENC=(-c:a aac -b:a "$A_BITRATE" -ar 48000 -ac 2)
else
  SCALE_CHAIN="fps=30,scale=1280:720:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"
  VID_ENC=(-c:v libx264 -preset "$CAP_PRESET" -tune zerolatency -crf "$CAP_CRF" -g 60 -bf 0 -pix_fmt yuv420p)
  AUD_ENC=(-c:a aac -b:a 160k -ar 48000 -ac 2)
fi

echo "=== Capture (BD mode: $BLURAY_MODE) === $VIDEO_DEV $IN_FMT → $OUT_MP4"

cleanup(){ for f in "$PREVIEW_FIFO" "$RECORD_FIFO"; do [[ -p "$f" ]] && rm -f "$f" || true; done; }
trap cleanup EXIT
rm -f "$PREVIEW_FIFO" "$RECORD_FIFO" 2>/dev/null || true
mkfifo "$PREVIEW_FIFO" "$RECORD_FIFO"

ffplay -hide_banner -fflags nobuffer -flags low_delay -framedrop -fs -window_title "$WINDOW_TITLE" -i "$PREVIEW_FIFO" &
PREVIEW_PID=$!

ffmpeg -hide_banner -y -i "$RECORD_FIFO" \
  -map 0:v -map 0:a -c:v copy -c:a aac -b:a 128k -ar 48000 -ac 2 -bsf:a aac_adtstoasc \
  -movflags +faststart "$OUT_MP4" &
REC_PID=$!

ffmpeg -hide_banner -nostdin \
  -fflags +nobuffer+discardcorrupt -flags low_delay -use_wallclock_as_timestamps 1 -rtbufsize 128M \
  -thread_queue_size 1024 -f v4l2 -input_format "$IN_FMT" -i "$VIDEO_DEV" \
  -thread_queue_size 512  -f pulse -ac 2 -ar 48000 -i "$AUDIO_SRC" \
  -map 0:v -map 1:a -vf "$SCALE_CHAIN" \
  "${VID_ENC[@]}" "${AUD_ENC[@]}" \
  -f tee "[f=mpegts]$PREVIEW_FIFO|[f=mpegts]$RECORD_FIFO"

echo "▶ Recording -> $OUT_MP4"
while read -r -t 0.1 -n 1 _; do :; done 2>/dev/null || true
while true; do read -r -n 1 k; [[ "$k" == q ]] && { kill -INT "$REC_PID"; wait "$REC_PID" 2>/dev/null || true; echo "Saved: $OUT_MP4"; break; }; done
wait "$PREVIEW_PID" 2>/dev/null || true
