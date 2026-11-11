# Releases

This fork keeps upstream's `rexurrect` command, runtime configuration and
optional zsh recorder. Its functional changes are the bounded scrollback read,
preservation of default HOME shell sessions, and saving command blocks kept open
after their commands exit. Rust/Cargo are pinned to
1.89.0; dependencies remain locked.

## Install and update

The supported prebuilt target is currently Apple Silicon macOS:

```sh
brew tap tru2dagame/tap
brew install tru2dagame/tap/rexurrect
brew upgrade tru2dagame/tap/rexurrect
```

The Formula installs the release binary directly and the optional recorder
under `share/rexurrect`. No local compilation or command wrapper is required.
`rexurrect setup` and `rexurrect autosave install` retain their upstream behavior;
installation alone does not enable autosave or auto-restore.

The standard cargo-dist shell installer remains available for manual installs.
Use an explicit release URL to select a reviewed version. Do not mix Homebrew
and shell-installed executables on `PATH`.

## Prepare a release

1. Review source and upstream changes, then run `scripts/release.sh --check` and
   `--build` from clean signed source. The helper does not commit, tag, push or
   publish. Versioned releases keep the normal cargo-dist archive, checksum,
   shell installer and generated Homebrew Formula.
2. The generated GitHub workflow's manual `dry-run` selection builds candidate
   artifacts without publishing. Select the reviewed workflow ref and check
   the run's actual commit; its tag input does not select a different checkout.
3. Verify the exact archive checksum and available repository-bound provenance:

   ```sh
   gh attestation verify rexurrect-aarch64-apple-darwin.tar.xz --repo tru2dagame/rexurrect
   ```

   A provenance claim needs a matching attestation, not just a supplied commit.
   The local verifier runs the full private Rex tests against the extracted
   binary. With pinned Rust/Cargo on `PATH` and an absolute Rex CLI in `REX_BIN`:

   ```sh
   scripts/verify-release-artifact.sh archive.tar.xz <archive-sha256> \
     v0.4.2 <reviewed-source-commit> /new/outside/checkout/acceptance
   ```

4. After review/authorization, tag the accepted source and publish the accepted
   assets. Use `gh release create --draft
   --verify-tag --repo tru2dagame/rexurrect` with explicit assets for a reviewable
   release draft. A real-tag workflow dispatch rebuilds and publicly releases
   its own bytes; it does not promote a previously accepted candidate.
5. Review cargo-dist's `rexurrect.rb`: URL, version, archive SHA-256, supported
   architecture and recorder installation. Update `Formula/rexurrect.rb` in
   `tru2dagame/homebrew-tap` through a signed commit and reviewed push. The tap
   must point to the exact accepted archive. Test the Formula before rollout.

`dist-workspace.toml` enables standard Homebrew generation but deliberately uses
`publish-jobs = []`. Updating the tap is manual, so CI needs no cross-repository
token. Releases use ordinary stable version tags such as `v0.4.2`; no special
version suffix is needed. Do not assume that publishing a GitHub Release
updated the tap.

Regenerate `.github/workflows/release.yml` with cargo-dist 0.33.1 after changing
its configuration. Upstream review, source push, artifact acceptance, Release
publication, tap update and installation remain separate actions. Existing
published artifacts stay pinned; packaging changes apply to a future release.
