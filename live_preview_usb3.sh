#!/usr/bin/env bash
# Live preview for USB3 capture — auto-discovery for video & audio
set -Eeuo pipefail

# ── Defaults (override with env) ──────────────────────────────────────────────
PIPE="${PIPE:-nut}"             # direct | split | nut
MODE="${MODE:-ps4_low}"           # ps4_low | ps4_hi | ps4_ultra_low
VIDEO_DEV="${VIDEO_DEV:-auto}"    # auto | /dev/videoN

AUDIO_MODE="${AUDIO_MODE:-alsa}"  # alsa | pulse | none
ALSA_DEV="${ALSA_DEV:-auto}"      # auto | hw:X,Y
PULSE_SOURCE="${PULSE_SOURCE:-@DEFAULT_SOURCE@}"

FULLSCREEN="${FULLSCREEN:-1}"
VOL_DB="${VOL_DB:-8}"

PROBESIZE="${PROBESIZE:-128k}"
ANALYZE="${ANALYZE:-0}"
RTBUF="${RTBUF:-128M}"

need(){ command -v "$1" &>/dev/null || { echo "Missing '$1' — sudo apt install $1" >&2; exit 1; }; }
need ffmpeg; need ffplay; need v4l2-ctl
command -v arecord >/dev/null || true
command -v pactl >/dev/null || true

err(){ echo "[error] $*" >&2; exit 1; }
log(){ echo "[info] $*" >&2; }

# ── Mode → preferred format/size ─────────────────────────────────────────────
case "$MODE" in
  ps4_low)        PREF_PIX="MJPG"; WIDTH="${WIDTH:-1280}"; HEIGHT="${HEIGHT:-720}";  FPS="${FPS:-60}" ;;
  ps4_hi)         PREF_PIX="YUYV"; WIDTH="${WIDTH:-1920}"; HEIGHT="${HEIGHT:-1080}"; FPS="${FPS:-30}" ;;
  ps4_ultra_low)  PREF_PIX="MJPG"; WIDTH="${WIDTH:-960}";  HEIGHT="${HEIGHT:-540}";  FPS="${FPS:-60}" ;;
  *) err "Unknown MODE='$MODE' (use ps4_low|ps4_hi|ps4_ultra_low)";;
esac

# MJPG bandwidth guardrails
if [[ "$PREF_PIX" == "MJPG" ]]; then
  [[ "$WIDTH" -ge 1920 && "$FPS" -gt 50 ]] && FPS=50
  [[ "$WIDTH" -le 1280 && "$FPS" -gt 60 ]] && FPS=60
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
# Resolve best /dev/video* from by-id; prefer external capture sticks
discover_video_dev() {
  # 1) Strong signal: /dev/v4l/by-id/*-video-index0 (stable names)
  local byid dev
  for byid in /dev/v4l/by-id/*-video-index0; do
    [[ -e "$byid" ]] || continue
    dev="$(readlink -f "$byid")"
    # Skip obvious internal webcams if we can
    local card; card="$(v4l2-ctl -d "$dev" --all 2>/dev/null | grep -m1 'Card type' || true)"
    if grep -Eiq 'USB3|UVC|HDMI|Capture|Ultra|Elgato|Magewell|Mirabox|Aver|Camlink|Video' <<<"$card"; then
      echo "$dev"; return 0
    fi
  done

  # 2) Fallback: scan /dev/video* and pick one that looks like a capture stick
  local node
  for node in /dev/video*; do
    [[ -e "$node" ]] || continue
    local card; card="$(v4l2-ctl -d "$node" --all 2>/dev/null | grep -m1 'Card type' || true)"
    if grep -Eiq 'USB3|UVC|HDMI|Capture|Ultra|Elgato|Magewell|Mirabox|Aver|Camlink|Video' <<<"$card"; then
      echo "$node"; return 0
    fi
  done

  # 3) Last resort: first video device
  ls /dev/video* 2>/dev/null | head -n1
}

# Check if device supports a FOURCC at any resolution
supports_fourcc() {
  local dev="$1" fourcc="$2"
  v4l2-ctl -d "$dev" --list-formats 2>/dev/null | grep -q "^\s*\[\S+\]: '${fourcc}'"
}

# Try to set format; degrade FPS if needed to avoid driver balks
apply_video_format() {
  local dev="$1" fourcc="$2" w="$3" h="$4" f="$5"
  v4l2-ctl -d "$dev" --set-fmt-video=width="$w",height="$h",pixelformat="$fourcc" >/dev/null 2>&1 || return 1
  # parm may fail on some drivers; try a few common rates
  v4l2-ctl -d "$dev" --set-parm="$f" >/dev/null 2>&1 || \
  v4l2-ctl -d "$dev" --set-parm=50 >/dev/null 2>&1 || \
  v4l2-ctl -d "$dev" --set-parm=30 >/dev/null 2>&1 || true
  # softer ask for MJPG efficiency
  [[ "$fourcc" == "MJPG" ]] && v4l2-ctl -d "$dev" --set-ctrl=compression_quality=70 >/dev/null 2>&1 || true
  return 0
}

# Pick ALSA USB capture (hw:X,Y) if available
discover_alsa_dev() {

# Hard-select hw:1,0 if present and ALSA is auto
if [[ "$AUDIO_MODE" == "alsa" && "$ALSA_DEV" == "auto" ]]; then
  if arecord -l 2>/dev/null | grep -q "card 1: Video .* device 0"; then
    ALSA_DEV="hw:1,0"
    log "Selected ALSA USB3 Video at ${ALSA_DEV}"
  fi
fi
  [[ "${AUDIO_MODE}" != "alsa" ]] && return 0
  [[ "${ALSA_DEV}" != "auto" ]] && return 0
  if command -v arecord >/dev/null; then
    local line card dev
    # Prefer USB or HDMI capture endpoints
    while read -r line; do
      if grep -Eiq 'USB|UAC|HDMI|Capture|Video' <<<"$line"; then
        card="$(sed -nE 's/^card ([0-9]+).*/\1/p' <<<"$line")"
        dev="$(sed -nE 's/.*device ([0-9]+).*/\1/p' <<<"$line")"
        if [[ -n "$card" && -n "$dev" ]]; then
          ALSA_DEV="hw:${card},${dev}"
          log "Auto-selected ALSA: ${ALSA_DEV}"
          return 0
        fi
      fi
    done < <(arecord -l 2>/dev/null || true)
  fi
  # Fallback if nothing matched
  ALSA_DEV="${ALSA_DEV:-hw:1,0}"
}

# Build ffplay/ffmpeg audio inputs/effects
build_audio_in() {
  case "$AUDIO_MODE" in
    alsa)  echo "-thread_queue_size 2048 -f alsa  -ac 2 -i ${ALSA_DEV}" ;;
    pulse) echo "-thread_queue_size 2048 -f pulse -ac 2 -i ${PULSE_SOURCE}" ;;
    none)  echo "" ;;
    *)     err "AUDIO_MODE must be alsa|pulse|none" ;;
  esac
}

build_audio_fx() {
  [[ "$AUDIO_MODE" == "none" ]] && echo "" \
    || echo "-filter:a aresample=48000:async=1:min_hard_comp=0.10:first_pts=0,volume=${VOL_DB}dB"
}

# ── Auto discovery ───────────────────────────────────────────────────────────
if [[ "$VIDEO_DEV" == "auto" ]]; then
  VIDEO_DEV="$(discover_video_dev)"
  [[ -n "${VIDEO_DEV}" && -e "${VIDEO_DEV}" ]] || err "No V4L2 video devices found."
  log "Selected video device: ${VIDEO_DEV}"
fi

discover_alsa_dev

# Decide working FOURCC (prefer PREF_PIX, then fallback)
FOURCC="$PREF_PIX"
if ! supports_fourcc "$VIDEO_DEV" "$FOURCC"; then
  log "Device does not report support for ${FOURCC}; trying fallback."
  if [[ "$FOURCC" == "MJPG" ]] && supports_fourcc "$VIDEO_DEV" "YUYV"; then
    FOURCC="YUYV"
  elif [[ "$FOURCC" == "YUYV" ]] && supports_fourcc "$VIDEO_DEV" "MJPG"; then
    FOURCC="MJPG"
  else
    # last resort: first listed format
    FOURCC="$(v4l2-ctl -d "$VIDEO_DEV" --list-formats 2>/dev/null | sed -nE "s/^\s*\[[0-9]+\]: '([A-Z0-9]{4})'.*/\1/p" | head -n1)"
    [[ -z "$FOURCC" ]] && err "Could not determine a usable pixel format for ${VIDEO_DEV}"
  fi
  log "Using FOURCC=${FOURCC}"
fi

# Map FOURCC → ffplay input_format token
case "$FOURCC" in
  MJPG) IN_PIX="mjpeg" ;;
  YUYV) IN_PIX="yuyv422" ;;
  *)    IN_PIX="$(tr '[:upper:]' '[:lower:]' <<<"$FOURCC")" ;; # best effort
esac

# Apply the chosen format/size/fps (with graceful fallback if exact size fails)
if ! apply_video_format "$VIDEO_DEV" "$FOURCC" "$WIDTH" "$HEIGHT" "$FPS"; then
  log "Exact ${WIDTH}x${HEIGHT}@${FPS} not accepted; trying safer presets…"
  # Try common safe presets
  for combo in \
    "1280x720x60" "1280x720x30" \
    "1920x1080x30" "1920x1080x60" \
    "960x540x60" "640x480x30"
  do
    W="${combo%x*}"; rest="${combo#*x}"; H="${rest%x*}"; F="${combo##*x}"
    if apply_video_format "$VIDEO_DEV" "$FOURCC" "$W" "$H" "$F"; then
      WIDTH="$W"; HEIGHT="$H"; FPS="$F"
      log "Fell back to ${WIDTH}x${HEIGHT}@${FPS}"
      break
    fi
  done
fi

# Window flag
fs=""; [[ "$FULLSCREEN" == "1" ]] && fs="-fs"

AIN="$(build_audio_in)"
AFX="$(build_audio_fx)"

echo "=== Preview:${PIPE} — ${WIDTH}x${HEIGHT}@${FPS} ${IN_PIX}/${FOURCC} | VIDEO_DEV=${VIDEO_DEV} | AUDIO=${AUDIO_MODE} ${AUDIO_MODE:+(${ALSA_DEV:-})} ==="

# ── Pipelines ────────────────────────────────────────────────────────────────
case "$PIPE" in
  direct)
    ffplay -hide_banner -loglevel warning \
      -fflags nobuffer+discardcorrupt+genpts+igndts -flags low_delay -framedrop \
      -probesize 32k -analyzeduration 0 \
      -window_title "USB3 Live Preview (direct video)" $fs \
      -f v4l2 -ts mono2abs \
      -input_format "$IN_PIX" -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" \
      -i "$VIDEO_DEV"
    ;;
  split)
    if [[ "$AUDIO_MODE" != "none" ]]; then
      ffplay -nodisp -hide_banner -loglevel warning \
        -fflags nobuffer -flags low_delay \
        $( [[ "$AUDIO_MODE" == "alsa"  ]] && echo "-f alsa  -ac 2 -i ${ALSA_DEV}" ) \
        $( [[ "$AUDIO_MODE" == "pulse" ]] && echo "-f pulse -ac 2 -i ${PULSE_SOURCE}" ) \
        -af "aresample=48000:async=1:first_pts=0,volume=${VOL_DB}dB" >/dev/null 2>&1 &
      AUDIO_PID=$!
    fi
    ffplay -hide_banner -loglevel warning \
      -fflags nobuffer+discardcorrupt+genpts+igndts -flags low_delay -framedrop \
      -probesize 32k -analyzeduration 0 \
      -window_title "USB3 Live Preview (split AV)" $fs \
      -f v4l2 -ts mono2abs \
      -input_format "$IN_PIX" -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" \
      -i "$VIDEO_DEV"
    [[ -n "${AUDIO_PID:-}" ]] && kill "$AUDIO_PID" >/dev/null 2>&1 || true
    ;;
  nut)
    ffmpeg -hide_banner -loglevel warning -nostdin \
      -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
      -fflags +nobuffer+flush_packets+discardcorrupt+genpts+igndts -flags low_delay \
      -err_detect ignore_err \
      -rtbufsize "$RTBUF" \
      -thread_queue_size 1024 \
      -f v4l2 -ts mono2abs -use_wallclock_as_timestamps 1 \
      -input_format "$IN_PIX" -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" -i "$VIDEO_DEV" \
      $AIN \
      -map 0:v ${AUDIO_MODE:+-map 1:a} \
      -c:v copy -fps_mode passthrough \
      ${AUDIO_MODE:+-c:a aac -b:a 128k -ar 48000 $AFX} \
      -max_delay 0 -avioflags direct -muxpreload 0 -muxdelay 0 \
      -f matroska - \
    | ffplay -hide_banner -loglevel warning \
        -fflags nobuffer+discardcorrupt+genpts+igndts -flags low_delay -framedrop \
        -probesize 32k -analyzeduration 0 \
        -sync video \
        -window_title "USB3 Live Preview (mkv pipe)" $fs -i -
    ;;
  *) err "PIPE must be direct|split|nut" ;;
esac
