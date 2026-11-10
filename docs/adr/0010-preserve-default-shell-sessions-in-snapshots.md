# Preserve default shell sessions in snapshots

## Decision

Save every session that has at least one window. Retain the existing rule that
a session with no windows is left out. Keep `is_untouched` unchanged for its
separate use in app-session cleanup; it no longer decides snapshot eligibility.

This changes the snapshot interpretation of an empty server used by ADR-0009:
an empty server has no windowed sessions, rather than also including default
home-directory shells. The existing emptied-instance, failed-restore and
carried-over-session safeguards remain unchanged.

## Evidence

The upstream save path checks `is_untouched` before capturing scrollback. One
default window and shell in HOME, with no recorded last command, is discarded
even if its terminal has output. Manual saves and autosaves take the same path.
The original integration test printed 20,000 lines and explicitly expected
them to be discarded. A successful save therefore did not mean every live
window or its output had been captured.

Session names do not disambiguate activity, and without a recorder a completed
short command leaves the shell as the foreground process. Reading scrollback
after filtering cannot correct this decision. Shell startup banners and prompts
also mean that a nonempty VT export cannot reliably distinguish an abandoned
default window from useful output. Guessing that distinction risks more loss.

## Consequences

- HOME shells preserve scrollback without a custom tab name or a command hook.
- Empty/default windows may also be restored. This is deliberate: retaining an
  extra window is preferable to silently discarding output.
- The command now matches its description of saving every windowed session.
- No snapshot format, terminal replay, retention limit, program auto-resume,
  server selection or native app-session cleanup behavior changes.
- Existing snapshots that omitted a session remain unable to restore it. The
  change protects future snapshots and cannot reconstruct missing past output.
