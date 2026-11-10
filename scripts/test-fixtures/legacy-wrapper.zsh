#!/bin/zsh
# Run the fixed local fork with its own manual-trial snapshots and settings.
set -euo pipefail

task_commit=dbdde1d4b5d2d8bc6ab936eec98e980c939126e5
task_expected_sha=b0c891ee850f1acfd76d71da4135fb275496b1d9880b9650fddb1691085c1a94
task_binary="$HOME/.local/libexec/rexurrect/$task_commit/rexurrect"
[[ -x "$task_binary" ]] || { print -u2 -- "Missing pinned binary: $task_binary"; exit 1; }
task_binary_sha=$(/usr/bin/shasum -a 256 "$task_binary")
[[ "${task_binary_sha%% *}" == "$task_expected_sha" ]] || {
  print -u2 -- 'The pinned rexurrect binary has changed. Review it before running.'
  exit 1
}

export REX_SERVER="${REX_SERVER:-unix://$HOME/Library/Application%20Support/rex/server.sock}"
export REXURRECT_STATE_DIR="$HOME/.local/state/rexurrect-fork-manual"
export REXURRECT_CONFIG="$HOME/.config/rexurrect-fork-manual/config.toml"
task_rex_cli="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
[[ -x "$task_rex_cli" ]] || { print -u2 -- "Missing Rex CLI: $task_rex_cli"; exit 1; }
export PATH="${task_rex_cli:h}:$PATH"

case "${1:-help}" in
  --build-info)
    print -r -- "Fork commit: $task_commit"
    print -r -- "Binary SHA-256: $task_expected_sha"
    print -r -- "Rex endpoint: $REX_SERVER"
    print -r -- "Snapshot state: $REXURRECT_STATE_DIR"
    print -r -- "Config: $REXURRECT_CONFIG"
    exit 0
    ;;
  save|restore)
    print -u2 -r -- "Rex endpoint: $REX_SERVER"
    print -u2 -r -- "Snapshot state: $REXURRECT_STATE_DIR"
    ;;
esac

if (( $# == 0 )); then set -- help; fi
exec "$task_binary" "$@"
