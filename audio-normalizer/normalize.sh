#!/bin/bash
set -euo pipefail

# Audio Normalizer - Adds normalized audio track to video files
# Supports both standalone usage and Sonarr/Radarr post-processing

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
LOUDNESS_TARGET="${LOUDNESS_TARGET:--14}" # Target loudness in LUFS (Netflix uses -14, we use -16 for safety margin)
TEMP_DIR="${TEMP_DIR:-.}"
BACKUP_DIR="${BACKUP_DIR:-.backups}"

# Parse input - can be called from Sonarr/Radarr (via environment vars) or directly
INPUT_FILE=""

if [[ -n "${sonarr_moviefile_path:-}" ]]; then
  # Called from Sonarr (movie post-processing)
  INPUT_FILE="$sonarr_moviefile_path"
elif [[ -n "${sonarr_episodefile_path:-}" ]]; then
  # Called from Sonarr (episode post-processing)
  INPUT_FILE="$sonarr_episodefile_path"
elif [[ -n "${radarr_moviefile_path:-}" ]]; then
  # Called from Radarr
  INPUT_FILE="$radarr_moviefile_path"
elif [[ $# -eq 1 ]]; then
  # Called directly with file argument
  INPUT_FILE="$1"
else
  echo -e "${RED}Usage: $0 <input_file>${NC}"
  echo "Or set environment variables (sonarr_moviefile_path, sonarr_episodefile_path, radarr_moviefile_path)"
  exit 1
fi

# Validate input file
if [[ ! -f "$INPUT_FILE" ]]; then
  echo -e "${RED}Error: File not found: $INPUT_FILE${NC}"
  exit 1
fi

BASENAME=$(basename "$INPUT_FILE")
DIRNAME=$(dirname "$INPUT_FILE")
EXTENSION="${INPUT_FILE##*.}"
# Always output as MKV (supports H.265 + multi-audio better)
BASENAME_NO_EXT="${BASENAME%.*}"

# Temp files
AUDIO_ORIGINAL="${TEMP_DIR}/.audio_original_$$.aac"
AUDIO_NORMALIZED="${TEMP_DIR}/.audio_normalized_$$.aac"
LOUDNESS_STATS="${TEMP_DIR}/.loudness_$$.json"
OUTPUT_FILE="${DIRNAME}/.${BASENAME_NO_EXT}.tmp.mkv"
FINAL_FILE="${DIRNAME}/${BASENAME_NO_EXT}.mkv"

cleanup() {
  rm -f "$AUDIO_ORIGINAL" "$AUDIO_NORMALIZED" "$LOUDNESS_STATS" "$OUTPUT_FILE"
}
trap cleanup EXIT

log_info() {
  echo -e "${GREEN}[normalize]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[normalize]${NC} $1"
}

log_error() {
  echo -e "${RED}[normalize]${NC} $1"
}

# Check for ffmpeg
if ! command -v ffmpeg &>/dev/null; then
  log_error "ffmpeg not found. Please install it: sudo apt-get install ffmpeg"
  exit 1
fi

log_info "Processing: $BASENAME"

# Check if file already has multiple audio tracks
AUDIO_TRACK_COUNT=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$INPUT_FILE" | wc -l)
if [[ $AUDIO_TRACK_COUNT -gt 1 ]]; then
  log_warn "File already has $AUDIO_TRACK_COUNT audio tracks. Skipping."
  exit 0
fi

log_info "Extracting original audio..."
ffmpeg -i "$INPUT_FILE" -q:a 9 -map a:0 "$AUDIO_ORIGINAL" 2>/dev/null

if [[ ! -f "$AUDIO_ORIGINAL" ]]; then
  log_error "Failed to extract audio"
  exit 1
fi

log_info "Analyzing loudness (this may take a moment)..."
# Two-pass loudness normalization for accuracy
# Why: Single-pass normalization is less accurate, especially for content with varied dynamics
ffmpeg -i "$AUDIO_ORIGINAL" \
  -af "loudnorm=I=$LOUDNESS_TARGET:TP=-1.5:LRA=11:print_format=json" \
  -f null - 2>&1 | grep -A 20 "Parsed_loudnorm" >"$LOUDNESS_STATS" || true

# Extract normalization parameters from first pass
MEASURED_I=$(grep '"input_i"' "$LOUDNESS_STATS" | head -1 | grep -oP ':\s*\K-?[0-9.]+' || echo "0")
MEASURED_TP=$(grep '"input_tp"' "$LOUDNESS_STATS" | head -1 | grep -oP ':\s*\K-?[0-9.]+' || echo "0")
MEASURED_LRA=$(grep '"input_lra"' "$LOUDNESS_STATS" | head -1 | grep -oP ':\s*\K-?[0-9.]+' || echo "0")

log_info "Loudness: I=$MEASURED_I TP=$MEASURED_TP LRA=$MEASURED_LRA (target: I=$LOUDNESS_TARGET)"

log_info "Creating normalized audio track..."
# Second pass with measured values for consistent normalization
ffmpeg -i "$AUDIO_ORIGINAL" \
  -af "loudnorm=I=$LOUDNESS_TARGET:TP=-1.5:LRA=11:measured_I=$MEASURED_I:measured_TP=$MEASURED_TP:measured_LRA=$MEASURED_LRA" \
  -c:a aac -b:a 128k "$AUDIO_NORMALIZED" 2>/dev/null

if [[ ! -f "$AUDIO_NORMALIZED" ]]; then
  log_error "Failed to create normalized audio"
  exit 1
fi

log_info "Muxing audio tracks (keeping original as track 1, normalized as track 2)..."
# Why we use -c:v copy: The video is already encoded. Re-encoding would be slow and cause quality loss.
# We only transcode the audio (normalize), video stays completely untouched.
ffmpeg -i "$INPUT_FILE" \
  -i "$AUDIO_NORMALIZED" \
  -c:v copy \
  -c:a aac \
  -map 0:v:0 \
  -map 0:a:0 \
  -map 1:a:0 \
  -metadata:s:a:0 title="Original" \
  -metadata:s:a:1 title="Normalized" \
  -disposition:a:0 default \
  -disposition:a:1 0 \
  "$OUTPUT_FILE" 2>/dev/null

if [[ ! -f "$OUTPUT_FILE" ]]; then
  log_error "Failed to mux audio tracks"
  exit 1
fi

# Verify output
OUTPUT_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE")
ORIGINAL_SIZE=$(stat -f%z "$INPUT_FILE" 2>/dev/null || stat -c%s "$INPUT_FILE")

if [[ $OUTPUT_SIZE -lt $((ORIGINAL_SIZE / 2)) ]]; then
  log_error "Output file seems corrupted (too small: $OUTPUT_SIZE vs $ORIGINAL_SIZE)"
  exit 1
fi

log_info "Creating backup..."
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/$BASENAME_NO_EXT.mkv"
cp "$INPUT_FILE" "$BACKUP_FILE"

log_info "Replacing original file..."
mv "$OUTPUT_FILE" "$FINAL_FILE"

# If extension changed, remove the original file
if [[ "$EXTENSION" != "mkv" ]]; then
  rm "$INPUT_FILE"
  log_info "Removed original $EXTENSION file"
fi

log_info "Done! ✓"
log_info "File converted to MKV: $FINAL_FILE"
log_info "Original backed up to: $BACKUP_FILE"
log_info "New audio track 'Normalized' added (switch in player to use)"
