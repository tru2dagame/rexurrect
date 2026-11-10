#!/usr/bin/env bash
# Maintainer acceptance of one standard cargo-dist archive. No installation.
# The expected commit is operator-supplied; verify CI provenance separately.
set -euo pipefail
export LC_ALL=C
fail() { echo "artifact acceptance: $*" >&2; exit 1; }
[[ $# == 5 ]] || fail 'Usage: verify-release-artifact.sh ARCHIVE SHA256 vTAG EXPECTED_COMMIT REPORT_DIR'
archive=$1 expected_sha=$2 tag=$3 expected_commit=$4 report_dir=$5
[[ ! -e "$report_dir" ]] || fail 'Use a new report directory for each acceptance run.'
[[ -f "$archive" && ! -L "$archive" ]] || fail 'Archive must be a regular file.'
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ && "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'Use full SHA-256 and commit values.'
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-tru\.[0-9]+$ ]] || fail 'Use an explicit fork tag such as v0.4.0-tru.1.'
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
mkdir -p "$report_dir"
report_dir=$(cd -- "$report_dir" && pwd -P)
case "$report_dir/" in "$root/"*) fail 'Report directory must be outside the checkout.' ;; esac
[[ "$(git -C "$root" rev-parse HEAD)" == "$expected_commit" ]] || fail 'Checkout HEAD differs from EXPECTED_COMMIT.'
[[ -z "$(git -C "$root" status --porcelain)" ]] || fail 'Use a clean source checkout.'
version=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$root/Cargo.toml" | head -n 1)
[[ "$tag" == "v$version" ]] || fail 'Cargo version differs from the requested tag.'
[[ -n "${REX_BIN:-}" && "$REX_BIN" == /* && -x "$REX_BIN" ]] || fail 'Set REX_BIN to the absolute Rex CLI path.'
compiler=${RUSTC:-$(command -v rustc)}
rust_version=$("$compiler" --version)
cargo_version=$(cargo --version)
[[ "$rust_version" == 'rustc 1.89.0 '* && "$cargo_version" == 'cargo 1.89.0 '* ]] || fail 'Use the pinned Rust and Cargo 1.89.0 toolchain.'
scratch=$(mktemp -d "${TMPDIR:-/tmp/}rexurrect-accept.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
cp "$archive" "$scratch/package.tar.xz"
actual_sha=$(shasum -a 256 "$scratch/package.tar.xz"); actual_sha=${actual_sha%% *}
[[ "$actual_sha" == "$expected_sha" ]] || fail 'Archive checksum mismatch.'
prefix=rexurrect-aarch64-apple-darwin
tar -tJf "$scratch/package.tar.xz" > "$scratch/names"
[[ -z "$(sort "$scratch/names" | uniq -d)" ]] || fail 'Archive contains duplicate paths.'
while IFS= read -r entry; do
  [[ "$entry" == "$prefix/"* ]] || fail "Unexpected archive path: $entry"
  case "/$entry/" in *'/../'*|*'/./'*) fail "Unsafe archive path: $entry" ;; esac
done < "$scratch/names"
[[ "$(grep -Fxc "$prefix/rexurrect" "$scratch/names")" == 1 ]] || fail 'Archive must contain one expected binary.'
tar -tvJf "$scratch/package.tar.xz" > "$scratch/types"
while IFS= read -r entry; do
  [[ "$entry" == -* || "$entry" == d* ]] || fail 'Archive contains links or special files.'
done < "$scratch/types"
# Only the binary is extracted; archive paths never become output paths.
tar -xJOf "$scratch/package.tar.xz" "$prefix/rexurrect" > "$scratch/rexurrect"
chmod 0700 "$scratch/rexurrect"
[[ "$(/usr/bin/lipo -archs "$scratch/rexurrect")" == arm64 ]] || fail 'Expected an arm64 binary.'
/usr/bin/codesign --verify --strict "$scratch/rexurrect"
[[ "$("$scratch/rexurrect" --version)" == "rexurrect $version" ]] || fail 'Binary version differs from source.'
binary_sha=$(shasum -a 256 "$scratch/rexurrect"); binary_sha=${binary_sha%% *}
"$REX_BIN" --autostart=false version > "$report_dir/rex-version.txt"
export REXURRECT_TEST_BIN="$scratch/rexurrect" RUSTC="$compiler" RUSTUP_TOOLCHAIN=1.89.0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$scratch/cargo-target}"
unset REX_SERVER REX_SESSION REX_BLOCK REXURRECT_STATE_DIR REXURRECT_CONFIG
cd "$root"
test_exit=0
cargo test --frozen --tests -- --test-threads=4 > "$report_dir/tests.log" 2>&1 || test_exit=$?
read -r passed failed < <(awk '/^test result:/ { p += $4; f += $6 } END { print p+0, f+0 }' "$report_dir/tests.log")
result=failed
if [[ "$test_exit" == 0 && "$passed" -gt 0 && "$failed" == 0 ]] &&
   grep -Fq 'test a_home_shell_without_a_recorder_keeps_20000_lines_after_a_manual_save_and_restart ... ok' "$report_dir/tests.log" &&
   grep -Fq 'test colored_unicode_scrollback_over_one_mib_survives_a_server_restart_in_full ... ok' "$report_dir/tests.log"; then
  [[ -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$expected_commit" ]] || fail 'Source changed during acceptance.'
  after_sha=$(shasum -a 256 "$scratch/rexurrect"); after_sha=${after_sha%% *}
  [[ "$after_sha" == "$binary_sha" ]] || fail 'Test artifact changed during acceptance.'
  result=passed
fi
{
  echo "status=$result"
  echo "verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repository=tru2dagame/rexurrect"
  echo "expected_source_commit=$expected_commit (operator-supplied; verify CI provenance separately)"
  echo "tag=$tag"
  echo "archive_sha256=$actual_sha"
  echo "binary_sha256=$binary_sha"
  echo "toolchain=$rust_version; $cargo_version"
  echo "test_exit=$test_exit; passed=$passed; failed=$failed"
  echo "Rex build metadata: rex-version.txt; complete private-fixture test output: tests.log"
} > "$report_dir/REPORT.txt.tmp"
mv -f "$report_dir/REPORT.txt.tmp" "$report_dir/REPORT.txt"
cat "$report_dir/REPORT.txt"
[[ "$result" == passed ]]
