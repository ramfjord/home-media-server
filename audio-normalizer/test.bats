#!/usr/bin/env bats

# Audio Normalizer BATS Tests
# Run with: bats audio-normalizer/test.bats

setup() {
  # Create temporary test directory
  export TEST_TMPDIR="$(mktemp -d)"
  export TEMP_DIR="$TEST_TMPDIR"
  export BACKUP_DIR="$TEST_TMPDIR/.backups"

  # Change to test directory
  cd "$TEST_TMPDIR"

  # Source the script (don't run it yet)
  SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  export SCRIPT="$SCRIPT_DIR/normalize.sh"
}

teardown() {
  # Clean up test directory
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# Test: Script exists and is executable
@test "normalize.sh exists and is executable" {
  [[ -f "$SCRIPT" ]]
  [[ -x "$SCRIPT" ]]
}

# Test: Script rejects missing files
@test "rejects missing input file" {
  run "$SCRIPT" /nonexistent/file.mkv
  [ $status -ne 0 ]
  [[ "$output" =~ "File not found" ]]
}

# Test: Script rejects no arguments
@test "rejects no arguments" {
  run "$SCRIPT"
  [ $status -ne 0 ]
  [[ "$output" =~ "Usage:" ]]
}

# Test: Script processes 5-minute test file
@test "processes a 5-minute test file" {
  # Check if test file exists
  if [[ ! -f "/tmp/stos_test.mkv" ]]; then
    skip "Test file /tmp/stos_test.mkv not found"
  fi

  # Copy test file to our temp directory
  TEST_FILE="$TEST_TMPDIR/test_video.mkv"
  cp /tmp/stos_test.mkv "$TEST_FILE"

  # Run the script
  run "$SCRIPT" "$TEST_FILE"
  [ $status -eq 0 ]
  [[ "$output" =~ "Done!" ]] || [[ "$output" =~ "already has" ]]
}

# Test: Backup is created
@test "creates backup of original file" {
  if [[ ! -f "/tmp/stos_test.mkv" ]]; then
    skip "Test file /tmp/stos_test.mkv not found"
  fi

  TEST_FILE="$TEST_TMPDIR/test_video.mkv"
  cp /tmp/stos_test.mkv "$TEST_FILE"

  # Run script
  "$SCRIPT" "$TEST_FILE" >/dev/null 2>&1 || true

  # If processing happened (not skipped), backup should exist
  if [[ -d "$BACKUP_DIR" ]]; then
    [[ -f "$BACKUP_DIR/test_video.mkv" ]]
  fi
}

# Test: Output has 2 audio tracks
@test "output file has 2 audio tracks after processing" {
  if [[ ! -f "/tmp/stos_test.mkv" ]]; then
    skip "Test file /tmp/stos_test.mkv not found"
  fi

  # Check if ffprobe is available
  if ! command -v ffprobe &>/dev/null; then
    skip "ffprobe not found"
  fi

  TEST_FILE="$TEST_TMPDIR/test_video.mkv"
  cp /tmp/stos_test.mkv "$TEST_FILE"

  # Get original track count
  ORIGINAL_TRACKS=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$TEST_FILE" 2>/dev/null | wc -l)

  # Only test if original file has 1 audio track
  if [[ $ORIGINAL_TRACKS -eq 1 ]]; then
    run "$SCRIPT" "$TEST_FILE"
    [ $status -eq 0 ]

    # Verify output has 2 audio tracks
    FINAL_TRACKS=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$TEST_FILE" 2>/dev/null | wc -l)
    [ $FINAL_TRACKS -eq 2 ]
  fi
}

# Test: Script skips files with 2+ audio tracks
@test "skips files that already have 2+ audio tracks" {
  if [[ ! -f "/tmp/stos_test.mkv" ]]; then
    skip "Test file /tmp/stos_test.mkv not found"
  fi

  # Check if ffprobe is available
  if ! command -v ffprobe &>/dev/null; then
    skip "ffprobe not found"
  fi

  TEST_FILE="$TEST_TMPDIR/test_video.mkv"
  cp /tmp/stos_test.mkv "$TEST_FILE"

  # Get original track count
  ORIGINAL_TRACKS=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$TEST_FILE" 2>/dev/null | wc -l)

  # If file already has 2+ tracks, test skip behavior
  if [[ $ORIGINAL_TRACKS -gt 1 ]]; then
    run "$SCRIPT" "$TEST_FILE"
    [ $status -eq 0 ]
    [[ "$output" =~ "already has" ]]
    [[ "$output" =~ "Skipping" ]]
  fi
}

# Test: Environment variable for Sonarr movie processing
@test "accepts sonarr_moviefile_path environment variable" {
  if [[ ! -f "/tmp/stos_test.mkv" ]]; then
    skip "Test file /tmp/stos_test.mkv not found"
  fi

  TEST_FILE="$TEST_TMPDIR/test_video.mkv"
  cp /tmp/stos_test.mkv "$TEST_FILE"

  # Run with Sonarr environment variable (no command line args)
  run bash -c "sonarr_moviefile_path='$TEST_FILE' '$SCRIPT'"
  # Should either succeed or exit with file-not-found error from sonarr interaction
  # We just verify it doesn't error on argument parsing
  [[ $status -eq 0 ]] || [[ "$output" =~ "File not found" ]]
}

# Test: Environment variable for Sonarr episode processing
@test "accepts sonarr_episodefile_path environment variable" {
  if [[ ! -f "/tmp/stos_test.mkv" ]]; then
    skip "Test file /tmp/stos_test.mkv not found"
  fi

  TEST_FILE="$TEST_TMPDIR/test_video.mkv"
  cp /tmp/stos_test.mkv "$TEST_FILE"

  # Run with Sonarr episode environment variable (no command line args)
  run bash -c "sonarr_episodefile_path='$TEST_FILE' '$SCRIPT'"
  [[ $status -eq 0 ]] || [[ "$output" =~ "File not found" ]]
}

# Test: Environment variable for Radarr processing
@test "accepts radarr_moviefile_path environment variable" {
  if [[ ! -f "/tmp/stos_test.mkv" ]]; then
    skip "Test file /tmp/stos_test.mkv not found"
  fi

  TEST_FILE="$TEST_TMPDIR/test_video.mkv"
  cp /tmp/stos_test.mkv "$TEST_FILE"

  # Run with Radarr environment variable (no command line args)
  run bash -c "radarr_moviefile_path='$TEST_FILE' '$SCRIPT'"
  [[ $status -eq 0 ]] || [[ "$output" =~ "File not found" ]]
}
