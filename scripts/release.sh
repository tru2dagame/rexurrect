#!/usr/bin/env bash
# Local release checks/builds only. Never commits, tags, pushes or publishes.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -1)
tag="v$version"
case "${1:---plan}" in
  --plan)
    [ "$#" -le 1 ] || exit 2
    echo "Release preparation: $tag"
    echo 'Review source, then create a signed commit when authorized.'
    echo 'Run scripts/release.sh --check, then --build from clean source.'
    echo 'Artifacts use the normal cargo-dist archive/checksum format.'
    echo 'Generated Release workflow: manual tag=dry-run builds candidates only.'
    echo 'Selecting an actual tag in that workflow PUBLICLY publishes a release.'
    echo 'For a reviewable draft, upload the tested exact assets with gh release create --draft.'
    echo 'Review the generated Formula and update tru2dagame/homebrew-tap with a signed commit.'
    ;;
  --check|--build)
    [ "$#" -eq 1 ] || exit 2
    if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
      echo 'Error: commit or stash source changes before release checks/builds' >&2
      exit 1
    fi
    if [[ "$(cargo --version)" != 'cargo 1.89.0 '* ]] || [[ "$(rustc --version)" != 'rustc 1.89.0 '* ]]; then
      echo 'Error: use the pinned Cargo/Rust 1.89.0 toolchain' >&2
      exit 1
    fi
    if [ "$1" = --check ]; then
      command -v rex >/dev/null || { echo 'Error: full isolated integration tests need rex on PATH' >&2; exit 1; }
      cargo fmt --check
      cargo clippy --all-targets --locked -- -D warnings
      for file in scripts/migrate-legacy-install.zsh scripts/test-migrate-legacy-install.zsh; do zsh -n "$file"; done
      zsh scripts/test-migrate-legacy-install.zsh
      env -u REXURRECT_TEST_BIN cargo test --locked -- --test-threads=4
    else
      dist_bin=${REXURRECT_DIST_BIN:-dist}
      [ "$("$dist_bin" --version)" = 'cargo-dist 0.33.1' ] || { echo 'Error: use cargo-dist 0.33.1' >&2; exit 1; }
      "$dist_bin" generate --check
      # Check locked dependency resolution first; dist itself has no --locked flag.
      cargo build --locked --profile dist --target aarch64-apple-darwin
      "$dist_bin" build --tag "$tag" --artifacts=all --target aarch64-apple-darwin
      git diff --exit-code -- Cargo.lock
      echo 'Built local artifacts in target/distrib; nothing was published.'
    fi
    ;;
  -h|--help)
    echo 'Usage: scripts/release.sh [--plan | --check | --build]'
    ;;
  *) echo 'Error: use --plan, --check or --build; implicit release/tag/push is disabled' >&2; exit 2 ;;
esac
