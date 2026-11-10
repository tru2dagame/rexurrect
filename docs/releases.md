# Release and migration notes

This fork uses cargo-dist 0.33.1 for the standard macOS arm64 `.tar.xz` archive,
checksum, shell installer and GitHub release workflow. Rust is pinned to 1.89.0.
The first fork version is `0.4.0-tru.1`, a prerelease selected explicitly by tag.
No custom archive format, Python release tools or version-management layer is
required. The two scrollback fixes remain separate source commits.

## Install and update rexurrect

Download `scripts/install.zsh` from the exact release tag and inspect it,
then run:

```sh
/bin/zsh install.zsh --version v0.4.0-tru.1 --autosave
```

Updating is the same operation with the new explicit release tag. The script
downloads cargo-dist's normal archive and `.sha256` file, verifies the payload,
and retains versioned binaries under `~/.local/libexec/rexurrect/`.
`~/.local/bin/rexurrect` is a self-contained checksum-pinned command wrapper.
An owned autosave job continues to point directly at the selected binary.
There is no `current.json`, separate managed launcher or background updater.

New installations use `~/.local/state/rexurrect` and
`~/.config/rexurrect/config.toml`. Existing trial snapshot/config paths,
endpoint, interval and enabled/loaded state are preserved during the command
rename. Unknown wrappers or jobs are rejected. New installations create a
900-second job only with `--autosave`. Installation does not run Rex save or
restore, restart the server, or edit shell/Lua settings.

Before replacement, the installer backs up the command wrappers and plist,
including which command names existed and the service state. It prints the
owned backup directory. Roll back
by selecting that exact backup, without downloading anything:

```sh
/bin/zsh install.zsh --rollback /absolute/path/to/installation-backup
```

The backup restores software selection and the job; snapshots/configuration are
not rolled back or deleted. Ordinary errors attempt to restore the backup. A
forced kill or power loss can prevent automatic cleanup; the self-contained
wrapper still refers to an existing binary, and explicit backup recovery is
the supported repair. If the install lock remains, first confirm the original
installer has exited, then remove only the empty
`~/.local/libexec/rexurrect/.install-lock` directory before running rollback.
There is no general transaction journal or guarantee of
atomic replacement across files and launchd. Keep the old binaries.

## Prepare and review a release

1. Review the fork source and create signed local commits. The release helper
   performs checks/preparation only; it does not commit, tag or push for you.
2. After push authorization, push the reviewed branch and register the generated
   release workflow on the fork's default branch. Run its `dry-run` selection
   to build candidate artifacts without a public release.
3. Download the exact standard archive. Verify its approved checksum and, where
   available, repository-bound attestation. Select the reviewed ref explicitly
   when dispatching and check the run's actual commit. The workflow's tag input
   selects the release version; it does not independently check out that tag.
   Run the thin verifier on a Mac with Rex (pinned Rust/Cargo on PATH and
   `REX_BIN` set to the absolute Rex CLI path):

   ```sh
   scripts/verify-release-artifact.sh archive.tar.xz <archive-sha256> \
     v0.4.0-tru.1 <reviewed-source-commit> /outside/checkout/acceptance
   ```

   It tests the actual extracted binary through private test sockets and
   synthetic data. Its expected commit is operator-supplied; CI provenance is
   checked separately. Use a new report directory for each run so a previous
   passing report cannot be confused with a failed rerun.
4. Review the source/tag/checksums/test log before any real release operation.
   After tag/push authorization, create the signed release tag at that exact
   commit. To keep the accepted bytes, use ordinary `gh release create` with
   `--draft --prerelease --latest=false --verify-tag --repo tru2dagame/rexurrect`
   and an explicit list of the accepted archive/checksum/installer assets, then
   publish that draft only after approval. No custom publisher is needed.
   A non-dry-run workflow dispatch rebuilds and publicly releases its own bytes;
   it is not a draft-only build or a promotion of the accepted candidate.
5. Install the selected release on one Mac and verify its manual command and
   loaded autosave job before an authorized wider rollout.

The generated workflow is regenerated from `dist-workspace.toml`; do not hand
edit it. Upstream Homebrew publication is disabled. Upstream merges and client
updates remain explicit review decisions. Source push, candidate CI, Release
publication and installation are separate states.
