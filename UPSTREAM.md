# Fork baseline and upstream updates

This fork experiments with complete scrollback capture through Rex's bounded
`format` and `blob_read` responses. It does not install autosave or auto-restore
as part of building or testing.

The `preserve-shell-scrollback` branch also keeps every session with a window,
including HOME shells with default labels and no recorder. See
[ADR-0010](docs/adr/0010-preserve-default-shell-sessions-in-snapshots.md).
The `fork-release` branch adds minimal cargo-dist configuration and a thin
Shell migration script. See [release notes](docs/releases.md).

## Selected baseline

| Item | Fixed value |
| --- | --- |
| Upstream | `https://github.com/cemcatik/rexurrect` |
| Upstream release | `v0.4.0` |
| Upstream commit | `b9eb0836856e2c71876ee9582b3bfed072bb00fc` |
| Experiment branch | `chunked-scrollback` |
| Rust toolchain | `1.89.0`, in `rust-toolchain.toml` |
| Baseline `Cargo.lock` SHA-256 | `d92180fd0cd774b4b36c611dc5e9338e1d8041adba3a2d87e0b52f7fee56d02c` |

The fork's `main` is the imported upstream branch, not an approved installation
target. Build from a specific reviewed fork commit. Record that full commit and
the resulting binary's SHA-256 with the test results. This baseline is a source
and dependency pin, not a claim that all upstream code has had a security audit.

The fixes add no dependencies. Fork releases change only this package's own
version in `Cargo.lock`; dependency versions stay pinned. The hash above is
the original baseline. Use
`cargo ... --locked` for initial builds. After dependencies are fetched, use
`--frozen` for offline repeat builds. Do not resolve dependency updates as an
incidental part of a source merge.

Rex is an external runtime. Record the exact Rex CLI/server build used in each
validation; the Rust toolchain and lockfile do not fix Rex's version.

## Validation before use

With Rust 1.89.0 and the intended Rex CLI on `PATH` (or in `REX_BIN`):

```sh
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
RUSTDOCFLAGS='-D warnings' cargo doc --no-deps --document-private-items --locked
cargo test --locked
zsh -n rexurrect.plugin.zsh
cargo build --release --locked
```

The integration tests use dedicated temporary Rex sockets, state directories,
configuration files and synthetic terminal output. They do not restart the
normal Rex server. `tests/chunked_scrollback.rs` checks output larger than one
control response, Unicode, styles, complete line order, a server restart and
failed blob reads that must preserve the previous snapshot.

Do not run `rexurrect setup`, `autosave install` or the auto-restore hook merely
to validate a build: they enable persistent behavior. Deployment is a separate
step after testing. Do not use upstream `scripts/release.sh` for local builds;
it commits, tags and pushes, and can trigger publishing workflows. Upstream CI
also selects floating Rust `stable` explicitly, so `rust-toolchain.toml` alone
does not pin those workflows. Review the build/publishing path before using it
to distribute fork binaries.

## Reviewing upstream

Check upstream periodically and when a relevant security or compatibility fix
is announced. Keep this review manual; do not install automatic sync, merges or
dependency updates.

1. Fetch upstream refs without changing the checked-out branch:
   `git fetch upstream --tags`.
2. Create a review branch from the approved fork commit. Compare its selected
   upstream baseline with the exact proposed upstream commit.
3. Review source changes, `Cargo.toml`, `Cargo.lock`, build scripts, workflows,
   installation code and release behavior. Review dependency changes separately.
4. Merge only the reviewed upstream commit on the review branch. Resolve and
   review the chunked-scrollback changes, then run the validation above against
   the intended Rex build. Use a signed merge/commit.
5. Update the baseline table and record the new fork commit, lockfile digest,
   toolchain, binary digest and test evidence before approving installation.

Keep each local change small so it can be reviewed again after an upstream
merge. Existing binaries remain the installation baseline until a new build is
explicitly accepted.
