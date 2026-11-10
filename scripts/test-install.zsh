#!/bin/zsh
# Native integration tests: child HOME is private; system launchctl is never used.
set -euo pipefail
here=${0:A:h}; temp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}rexurrect-install-tests.XXXXXXXX")
trap '/bin/rm -rf "$temp"' EXIT
fail() { print -u2 -- "FAIL: $*"; exit 1; }
fixture="$temp/home"; tools="$temp/tools"; control="$temp/control"; releases="$temp/releases"
/bin/mkdir -p "$fixture" "$tools" "$control" "$releases"
touch "$fixture/.rexurrect-install-test"; print 0 > "$control/loaded"; print 0 > "$control/disabled"
cat > "$tools/launchctl" <<'CTL'
#!/bin/zsh
set -eu
print -r -- "$*" >> "$TEST_CONTROL/calls"
case "$1" in
  print-disabled) if [[ "$(<"$TEST_CONTROL/disabled")" == none ]]; then print '{}'; else print -r -- "{ \"io.github.cemcatik.rexurrect.autosave\" => $([[ "$(<"$TEST_CONTROL/disabled")" == 1 ]] && print true || print false) }"; fi ;;
  print) [[ "$(<"$TEST_CONTROL/loaded")" == 1 ]] || exit 113; print -rl -- "program = $(<"$TEST_CONTROL/program")" 'state = not running' ;;
  bootout) print 0 > "$TEST_CONTROL/loaded" ;;
  enable) print 0 > "$TEST_CONTROL/disabled" ;;
  disable) print 1 > "$TEST_CONTROL/disabled" ;;
  bootstrap)
    [[ ! -e "$TEST_CONTROL/fail-bootstrap-always" ]] || exit 5
    if [[ -e "$TEST_CONTROL/fail-bootstrap" ]]; then rm "$TEST_CONTROL/fail-bootstrap"; exit 5; fi
    [[ "$(<"$TEST_CONTROL/disabled")" == 0 ]] || exit 5
    /usr/bin/plutil -extract ProgramArguments.0 raw -o "$TEST_CONTROL/program" "$3"; print 1 > "$TEST_CONTROL/loaded" ;;
  *) exit 99 ;;
esac
CTL
cat > "$tools/curl" <<'CURL'
#!/bin/zsh
set -eu
for arg in "$@"; do [[ "$arg" != https://* ]] || url=$arg; done
out=${@[-1]}; cp "$TEST_RELEASES/${url:h:t}/${url:t}" "$out"
CURL
print -rl -- '#!/bin/zsh' 'exit 0' > "$tools/codesign"
print -rl -- '#!/bin/zsh' 'print arm64' > "$tools/lipo"
print -rl -- '#!/bin/zsh' 'print called > "$TEST_CONTROL/rex-called"; exit 99' > "$tools/rex"
chmod +x "$tools/"*
fake_rex="$fixture/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
mkdir -p "${fake_rex:h}"; cp "$tools/rex" "$fake_rex"
run() { /usr/bin/env HOME="$fixture" PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin" REXURRECT_INSTALL_TEST_HOME="$fixture" REXURRECT_INSTALL_TEST_BIN="$tools" TEST_CONTROL="$control" TEST_RELEASES="$releases" "$@"; }
install_release() { run /bin/zsh "$here/install.zsh" --version "$1" "${@[2,-1]}"; }
bad() { if "$@" > "$temp/rejected.log" 2>&1; then fail "Unexpected success: $*"; fi; }
asset=rexurrect-aarch64-apple-darwin.tar.xz; prefix=rexurrect-aarch64-apple-darwin
for version in v0.4.0-tru.1 v0.4.0-tru.2 v0.4.0-tru.3; do
  mkdir -p "$releases/$version/payload/$prefix"
  print -rl -- '#!/bin/zsh' "if [[ \"\${1:-}\" == --version ]]; then print 'rexurrect ${version#v}'; else print -r -- \"\$*\" >> \"\$TEST_CONTROL/binary-calls\"; fi" > "$releases/$version/payload/$prefix/rexurrect"
  chmod +x "$releases/$version/payload/$prefix/rexurrect"
  print fixture > "$releases/$version/payload/$prefix/LICENSE"
  /usr/bin/tar -cJf "$releases/$version/$asset" -C "$releases/$version/payload" "$prefix"
  value=$(/usr/bin/shasum -a 256 "$releases/$version/$asset"); { print -r -- "${value%% *} *$asset"; print; } > "$releases/$version/$asset.sha256"
done
wrapper="$fixture/.local/bin/rexurrect"; legacy_wrapper="$fixture/.local/bin/rexurrect-fork"; root="$fixture/.local/libexec/rexurrect"
state="$fixture/.local/state/rexurrect-fork-manual"; config="$fixture/.config/rexurrect-fork-manual/config.toml"
job="$fixture/Library/LaunchAgents/io.github.cemcatik.rexurrect.autosave.plist"
install_release v0.4.0-tru.1 > "$temp/fresh.log"; fresh_backup=$(sed -n 's/^Backup: //p' "$temp/fresh.log"); [[ ! -e "$job" ]] || fail 'Manual installation created autosave.'
install_release v0.4.0-tru.1 --autosave > "$temp/fresh-job.log"
[[ "$(/usr/bin/plutil -extract StartInterval raw -o - "$job")" == 900 && "$(<"$control/loaded")" == 1 ]] || fail 'Explicit autosave did not create the 15-minute job.'
[[ "$(run /bin/zsh "$wrapper" --build-info)" == *"$fixture/.local/state/rexurrect"* && "$(/usr/bin/plutil -extract EnvironmentVariables.REXURRECT_STATE_DIR raw -o - "$job")" == "$fixture/.local/state/rexurrect" ]] || fail 'Fresh installation did not use normal state paths.'
install_release v0.4.0-tru.2 > "$temp/normal-update.log"
normal_backup=$(sed -n 's/^Backup: //p' "$temp/normal-update.log")
run /bin/zsh "$here/install.zsh" --rollback "$normal_backup" > "$temp/normal-rollback.log"
[[ "$(run /bin/zsh "$wrapper" --version)" == 'rexurrect 0.4.0-tru.1' && "$(/usr/bin/plutil -extract EnvironmentVariables.REXURRECT_CONFIG raw -o - "$job")" == "$fixture/.config/rexurrect/config.toml" ]] || fail 'Normal update/rollback changed the config path.'
run /bin/zsh "$here/install.zsh" --rollback "$fresh_backup" > "$temp/fresh-rollback.log"
[[ ! -e "$wrapper" && ! -e "$legacy_wrapper" && ! -e "$job" && "$(<"$control/loaded")" == 0 ]] || fail 'Fresh rollback did not restore command/job absence.'
legacy_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$state" "${config:h}" "${wrapper:h}" "$root/$legacy_commit" "${job:h}"
print synthetic-state > "$state/sentinel"; print 'keep = 3' > "$config"
legacy="$root/$legacy_commit/rexurrect"
print -rl -- '#!/bin/zsh' "print 'rexurrect legacy'" > "$legacy"; chmod +x "$legacy"
legacy_sha=$(/usr/bin/shasum -a 256 "$legacy"); legacy_sha=${legacy_sha%% *}
/usr/bin/sed -E "s/^task_commit=.*/task_commit=$legacy_commit/;s/^task_expected_sha=.*/task_expected_sha=$legacy_sha/" "$here/test-fixtures/legacy-wrapper.zsh" > "$legacy_wrapper"; chmod +x "$legacy_wrapper"
/usr/bin/plutil -create xml1 "$job"
for key value in Label io.github.cemcatik.rexurrect.autosave; do /usr/bin/plutil -insert "$key" -string "$value" "$job"; done
/usr/bin/plutil -insert ProgramArguments -array "$job"; /usr/bin/plutil -insert ProgramArguments.0 -string "$legacy" "$job"; /usr/bin/plutil -insert ProgramArguments.1 -string save "$job"
/usr/bin/plutil -insert StartInterval -integer 1234 "$job"; /usr/bin/plutil -insert EnvironmentVariables -dictionary "$job"
for key value in REX_SERVER unix://fixture.sock REXURRECT_STATE_DIR "$state" REXURRECT_CONFIG "$config"; do /usr/bin/plutil -insert "EnvironmentVariables.$key" -string "$value" "$job"; done
print -r -- "$legacy" > "$control/program"; print 1 > "$control/loaded"; print 1 > "$control/disabled"
cp "$legacy_wrapper" "$temp/original-wrapper"; cp "$job" "$temp/original-job"
print foreign-command > "$wrapper"; bad install_release v0.4.0-tru.1
[[ "$(<"$wrapper")" == foreign-command && -e "$legacy_wrapper" ]] || fail 'Unknown canonical command was replaced.'
cmp "$temp/original-wrapper" "$legacy_wrapper"; cmp "$temp/original-job" "$job"; rm "$wrapper"
install_release v0.4.0-tru.1 > "$temp/install.log"
[[ -e "$wrapper" && ! -e "$legacy_wrapper" ]] || fail 'Legacy command was not migrated to rexurrect.'
[[ "$(run /bin/zsh "$wrapper" --build-info)" == *"$state"* && "$(/usr/bin/plutil -extract EnvironmentVariables.REXURRECT_CONFIG raw -o - "$job")" == "$config" ]] || fail 'Legacy migration changed state/config paths.'
/usr/bin/sed 's/^# Self-contained, checksum-pinned Rexurrect\.$/# Self-contained, checksum-pinned Rexurrect fork./;s/"Release:/"Fork release:/' "$wrapper" > "$temp/published-wrapper"
[[ "$(get_job=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$job"); print -r -- "$get_job")" == "$root/v0.4.0-tru.1/rexurrect" ]] || fail 'Job did not select release binary.'
[[ "$(<"$control/loaded")$(<"$control/disabled")" == 11 ]] || fail 'Loaded/disabled state changed.'
[[ "$(/usr/bin/plutil -extract StartInterval raw -o - "$job")" == 1234 ]] || fail 'Interval changed.'
backup=$(sed -n 's/^Backup: //p' "$temp/install.log")
install_release v0.4.0-tru.1 > "$temp/repeat.log"; grep -q 'Already installed' "$temp/repeat.log" || fail 'Repeated install was not a no-op.'
install_release v0.4.0-tru.2 > "$temp/update.log"
[[ "$(run /bin/zsh "$wrapper" --version)" == 'rexurrect 0.4.0-tru.2' ]] || fail 'Update wrapper selected wrong binary.'
run /bin/zsh "$here/install.zsh" --rollback "$backup" > "$temp/rollback.log"
[[ "$(run /bin/zsh "$legacy_wrapper" --version)" == 'rexurrect legacy' ]] || fail 'Legacy rollback failed.'
[[ ! -e "$wrapper" && -e "$legacy_wrapper" ]] || fail 'Legacy rollback did not restore command names.'
cmp "$temp/original-wrapper" "$legacy_wrapper"; cmp "$temp/original-job" "$job"
# Undoing this rollback must keep the current command until its replacement exists.
undo_backup=$(sed -n 's/^Backup: //p' "$temp/rollback.log")
if run /usr/bin/env REXURRECT_INSTALL_TEST_FAILPOINT=during-command-restore /bin/zsh "$here/install.zsh" --rollback "$undo_backup" > "$temp/undo-crash.log" 2>&1; then fail 'Undo-rollback test did not terminate.'; fi
[[ ! -e "$wrapper" && "$(run /bin/zsh "$legacy_wrapper" --version)" == 'rexurrect legacy' ]] || fail 'Interrupted undo removed its only command.'
rmdir "$root/.install-lock" # The marked child was killed and is no longer running.
run /bin/zsh "$here/install.zsh" --rollback "$undo_backup" > "$temp/undo-repair.log"
[[ ! -e "$legacy_wrapper" && "$(run /bin/zsh "$wrapper" --version)" == 'rexurrect 0.4.0-tru.2' && "$(<"$control/loaded")$(<"$control/disabled")" == 11 ]] || fail 'Explicit undo recovery failed.'
run /bin/zsh "$here/install.zsh" --rollback "$backup" > "$temp/undo-reset.log"
# The published v1 wrapper migrates even when the binary version is unchanged.
cp "$temp/published-wrapper" "$legacy_wrapper"
/usr/bin/plutil -remove ProgramArguments.0 "$job"; /usr/bin/plutil -insert ProgramArguments.0 -string "$root/v0.4.0-tru.1/rexurrect" "$job"; print -r -- "$root/v0.4.0-tru.1/rexurrect" > "$control/program"
install_release v0.4.0-tru.1 > "$temp/published-migration.log"
[[ -e "$wrapper" && ! -e "$legacy_wrapper" ]] || fail 'Same-version published wrapper migration was skipped.'
published_backup=$(sed -n 's/^Backup: //p' "$temp/published-migration.log")
run /bin/zsh "$here/install.zsh" --rollback "$published_backup" > "$temp/published-rollback.log"
cmp "$temp/published-wrapper" "$legacy_wrapper"; [[ ! -e "$wrapper" ]] || fail 'Published rollback left the new command.'
# Old backups called the legacy command file "wrapper"; restore that name.
old_backup="$state/install-backups/old-format"; mkdir "$old_backup"
print rexurrect-fork-backup-v1 > "$old_backup/marker"
for name in had_wrapper had_job loaded disabled; do print 1 > "$old_backup/$name"; done
cp "$temp/original-wrapper" "$old_backup/wrapper"; cp "$temp/original-job" "$old_backup/autosave.plist"
run /bin/zsh "$here/install.zsh" --rollback "$old_backup" > "$temp/old-format.log"
cmp "$temp/original-wrapper" "$legacy_wrapper"; cmp "$temp/original-job" "$job"; [[ ! -e "$wrapper" ]] || fail 'Old-format backup restored the wrong command name.'
touch "$control/fail-bootstrap"; bad install_release v0.4.0-tru.1
[[ "$(run /bin/zsh "$legacy_wrapper" --version)" == 'rexurrect legacy' && "$(<"$control/loaded")" == 1 ]] || { cat "$temp/rejected.log" >&2; cat "$control/calls" >&2; fail 'Failed update did not recover wrapper/job.'; }
# A plist default applies only when launchd has no explicit true/false override.
/usr/bin/plutil -insert Disabled -bool true "$job"
for override expected in none 1 0 0; do
  print 0 > "$control/loaded"; print -r -- "$override" > "$control/disabled"
  cp "$legacy_wrapper" "$temp/default-wrapper"; cp "$job" "$temp/default-job"
  install_release v0.4.0-tru.1 > "$temp/default.log"
  default_backup=$(sed -n 's/^Backup: //p' "$temp/default.log")
  [[ "$(<"$default_backup/disabled")" == "$expected" ]] || fail 'Wrong precedence for plist Disabled and launchd override.'
  run /bin/zsh "$here/install.zsh" --rollback "$default_backup" > "$temp/default-rollback.log"
  cmp "$temp/default-wrapper" "$legacy_wrapper"; cmp "$temp/default-job" "$job"
  [[ "$(<"$control/loaded")$(<"$control/disabled")" == "0$expected" ]] || fail 'Rollback changed the effective disabled state.'
done
/usr/bin/plutil -remove Disabled "$job"
# Even failed recovery must undo the temporary enable used for bootstrap.
print 1 > "$control/loaded"; print 1 > "$control/disabled"
cp "$legacy_wrapper" "$temp/failure-wrapper"; cp "$job" "$temp/failure-job"
touch "$control/fail-bootstrap-always"; bad install_release v0.4.0-tru.1
cmp "$temp/failure-wrapper" "$legacy_wrapper"; cmp "$temp/failure-job" "$job"
[[ "$(<"$control/loaded")$(<"$control/disabled")" == 01 ]] || fail 'Persistent bootstrap failure left the old job enabled.'
grep -q 'Job reload failed; recover manually' "$temp/rejected.log" || fail 'Failed recovery was not reported.'
rm "$control/fail-bootstrap-always"; print 1 > "$control/loaded"; print -r -- "$legacy" > "$control/program"
# An unsuccessful explicit rollback restores the newer installed state.
install_release v0.4.0-tru.1 > "$temp/rollback-failure.log"
rollback_backup=$(sed -n 's/^Backup: //p' "$temp/rollback-failure.log")
cp "$wrapper" "$temp/new-wrapper"; cp "$job" "$temp/new-job"
touch "$control/fail-bootstrap"; bad run /bin/zsh "$here/install.zsh" --rollback "$rollback_backup"
cmp "$temp/new-wrapper" "$wrapper"; cmp "$temp/new-job" "$job"
[[ "$(<"$control/loaded")$(<"$control/disabled")" == 11 ]] || fail 'Failed rollback did not recover the newer job state.'
run /bin/zsh "$here/install.zsh" --rollback "$rollback_backup" > "$temp/rollback-retry.log"
bad install_release v0.4.0-tru.1 --archive "$releases/v0.4.0-tru.1/$asset" --sha256 0000000000000000000000000000000000000000000000000000000000000000
cp "$legacy_wrapper" "$temp/known-wrapper"; print '# changed' >> "$legacy_wrapper"; bad install_release v0.4.0-tru.1; cp "$temp/known-wrapper" "$legacy_wrapper"
cp "$job" "$temp/known-job"; /usr/bin/plutil -replace ProgramArguments -json '["/foreign/rexurrect","save"]' "$job"; bad install_release v0.4.0-tru.1; cp "$temp/known-job" "$job"
mkdir -p "$temp/unsafe/$prefix"; ln -s /outside "$temp/unsafe/$prefix/rexurrect"; /usr/bin/tar -cJf "$temp/unsafe.tar.xz" -C "$temp/unsafe" "$prefix"
unsafe_sha=$(/usr/bin/shasum -a 256 "$temp/unsafe.tar.xz"); bad install_release v0.4.0-tru.1 --archive "$temp/unsafe.tar.xz" --sha256 "${unsafe_sha%% *}"
if run /usr/bin/env REXURRECT_INSTALL_TEST_FAILPOINT=after-wrapper /bin/zsh "$here/install.zsh" --version v0.4.0-tru.3 > "$temp/crash.log" 2>&1; then fail 'Crash test did not terminate.'; fi
[[ "$(run /bin/zsh "$wrapper" --version)" == 'rexurrect 0.4.0-tru.3' ]] || fail 'Complete wrapper unusable after interruption.'
[[ -e "$legacy_wrapper" ]] || fail 'Crash test missed the two-command activation window.'
[[ -d "$root/.install-lock" ]] || fail 'Crash must leave a lock for manual inspection.'
crash_backup=$(sed -n 's/^Backup: //p' "$temp/crash.log")
rmdir "$root/.install-lock" # The test knows its terminated child was the sole owner.
install_release v0.4.0-tru.3 > "$temp/finish-mixed.log"
mixed_backup=$(sed -n 's/^Backup: //p' "$temp/finish-mixed.log")
run /bin/zsh "$here/install.zsh" --rollback "$mixed_backup" > "$temp/mixed-rollback.log"
[[ -e "$wrapper" && -e "$legacy_wrapper" && "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$job")" == "$legacy" ]] || fail 'Mixed-state backup did not restore both commands and the old job.'
run /bin/zsh "$here/install.zsh" --rollback "$crash_backup" > "$temp/crash-repair.log"
[[ "$(run /bin/zsh "$legacy_wrapper" --version)" == 'rexurrect legacy' && "$(<"$control/loaded")$(<"$control/disabled")" == 11 ]] || fail 'Explicit backup did not repair the interrupted mixed state.'
[[ ! -e "$wrapper" ]] || fail 'Crash recovery did not remove the new canonical command.'
old_empty="$state/install-backups/old-empty"; mkdir "$old_empty"; print rexurrect-fork-backup-v1 > "$old_empty/marker"
for name in had_wrapper had_job loaded disabled; do print 0 > "$old_empty/$name"; done
run /bin/zsh "$here/install.zsh" --rollback "$old_empty" > "$temp/old-empty.log"
[[ ! -e "$wrapper" && ! -e "$legacy_wrapper" && ! -e "$job" && "$(<"$control/loaded")" == 0 ]] || fail 'Old-v1 fresh backup did not restore installation absence.'
[[ "$(<"$state/sentinel")" == synthetic-state && "$(<"$config")" == 'keep = 3' ]] || fail 'User data changed.'
[[ ! -e "$control/rex-called" && ! -e "$control/binary-calls" ]] || fail 'Installer ran Rex or a save/restore command.'
print 'PASS: native installer canonical/legacy commands, state paths, published-v1 backups, update, rollback, reload failure, corruption, interruption; isolated HOME and fake launchctl only.'
