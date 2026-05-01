# Audio Normalizer

Adds a normalized audio track to video files without re-encoding the video. Works standalone or as a Sonarr/Radarr post-processor.

## Why This Matters

- **No video re-encoding** — Video stream is copied as-is (fast, no quality loss)
- **Audio normalization only** — Uses ffmpeg's loudnorm filter with two-pass analysis for accuracy
- **Preserves original** — Keeps original audio as track 1, adds normalized as track 2
- **Backward compatible** — Plex/Jellyfin seamlessly play either track

## Installation

```bash
# Make sure ffmpeg is installed
sudo apt-get install ffmpeg

# Verify ffmpeg works
ffmpeg -version
```

## Comparison to ffmpeg-normalize

[ffmpeg-normalize](https://github.com/slhck/ffmpeg-normalize) is an excellent general-purpose audio normalization tool. This script exists for a specific use case:

| Feature | This Script | ffmpeg-normalize |
|---------|------------|------------------|
| **Multi-track output** | ✓ Adds normalized as track 2 | ✗ Replaces audio |
| **Preserve original** | ✓ Original always available | ✗ Not designed for this |
| **Video re-encoding** | ✗ Never | ✓ Optional |
| **Normalization methods** | 1 (EBU R128) | 3 (EBU R128, RMS, peak) |
| **Format support** | Any (via ffmpeg) | Any (via ffmpeg) |

**When to use this script:** You want to add a normalized audio track alongside the original, preserving both in a single file for later selection.

**When to use ffmpeg-normalize:** You want general-purpose audio normalization with multiple algorithms and don't need the original preserved.

## Usage

### Standalone (Manual/Batch Processing)

```bash
# Process a single file
./normalize.sh /path/to/video.mkv

# Batch process all files in a directory
for file in /media/TV/Star\ Trek/Season\ 1/*.m4v; do
    ./normalize.sh "$file"
done
```

**What happens:**
1. Original audio extracted
2. Two-pass loudness analysis (why two passes: single-pass is less accurate for varied dynamics)
3. Audio normalized to -16 LUFS (Netflix uses -14; we use -16 safety margin)
4. Both tracks muxed back (video copied untouched, not re-encoded)
5. Original backed up to `.backups/` folder
6. Normalized track added as "track 2" (original stays as default "track 1")

### Sonarr Post-Processing

1. In Sonarr settings: **Settings → Connect → Custom Scripts**
2. Add new script:
   - **Name**: Audio Normalizer
   - **Path**: `<install_base>/audio-normalizer/normalize.sh`
   - **Triggers**: On Import, On Upgrade

Sonarr will pass the file path automatically via environment variables.

### Radarr Post-Processing

Same as Sonarr, but in **Settings → Connect** for Radarr's custom scripts.

## Configuration

Edit variables at the top of `normalize.sh`:

```bash
LOUDNESS_TARGET="-16"      # Target loudness (LUFS). Lower = quieter target. -14 (Netflix) to -16 (safer)
TEMP_DIR="."               # Where to store temp files during processing
BACKUP_DIR=".backups"      # Where to store original files
```

## How It Works

### Why Two-Pass Normalization

The script measures loudness in the first pass, then applies calibrated normalization in the second pass. This is more accurate than single-pass because:
- Measures actual perceived loudness (LUFS units)
- Adapts to content with varying dynamics
- Prevents over-normalization

### Why Video Stays Untouched

The video is already compressed (H.264, H.265, VP9, etc.). Re-encoding it would:
- Take hours instead of minutes
- Introduce quality loss from double-compression
- Waste CPU cycles

By using `-c:v copy`, we just move the video stream into the new file without touching it.

### Audio Codec

Normalized audio is encoded as AAC 128kb/s because:
- Widely compatible (all devices/players)
- Smaller than lossless (FLAC) but transparent quality
- Original audio stays intact as fallback

## Troubleshooting

**"ffmpeg not found"** — Install ffmpeg:
```bash
sudo apt-get install ffmpeg
```

**Script hangs** — Two-pass analysis takes time (1-2 min per file). It's working, just be patient.

**Output file is corrupted** — Check disk space. The script creates temp files that need space.

**Audio levels still wrong** — Try adjusting `LOUDNESS_TARGET`:
- `-14` — Netflix standard, louder
- `-16` — Conservative, current default
- `-18` — Quieter, more dynamic range preserved

## Testing

### Manual Testing

Test with a single file before batch processing:

```bash
./normalize.sh /media/TV/Star\ Trek/Season\ 1/some_episode.m4v
```

Then play it in Plex/Jellyfin and listen to both audio tracks.

### Automated Testing with BATS

Run the automated test suite:

```bash
# Install BATS if not already installed
sudo apt-get install bats

# Run tests
bats audio-normalizer/test.bats

# Run with verbose output
bats -v audio-normalizer/test.bats
```

#### Test File Requirements

Tests require a sample video file at `/tmp/stos_test.mkv`. This file should be:
- **Format**: MKV (or any format ffmpeg supports)
- **Duration**: ~5 minutes (tests assume reasonable processing time)
- **Audio**: At least 1 audio track
- **Size**: Any reasonable size

Create a test file by extracting a portion of an existing video:

```bash
# Extract first 5 minutes of an existing video
ffmpeg -i /path/to/your/video.mkv -t 300 -c copy /tmp/stos_test.mkv
```

Or create a minimal test file:

```bash
# Create a silent 5-minute test video (H.264 + AAC audio)
ffmpeg -f lavfi -i color=c=black:s=1280x720:d=300 \
  -f lavfi -i anullsrc=r=44100:cl=mono:d=300 \
  -c:v libx264 -preset ultrafast \
  -c:a aac -b:a 128k \
  /tmp/stos_test.mkv
```

**Note:** Do not check the test file into git. Add `/tmp/stos_test.mkv` to your `.gitignore` if needed.

#### Test Coverage

The test suite covers:
- Script exists and is executable
- Rejects missing input files
- Rejects missing arguments
- Processes a 5-minute test file successfully
- Creates backup of original file
- Output file has correct number of audio tracks (2 after processing)
- Skips files already with 2+ audio tracks
- Accepts Sonarr/Radarr environment variables

## Backups

Original files are backed up to `.backups/` in the same directory as the video. Keep these around for a few weeks to verify everything works before deleting.

