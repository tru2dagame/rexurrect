#!/bin/zsh
# All data and commands below belong to a marked temporary HOME.
set -euo pipefail
here=${0:A:h}; temp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}rexurrect-migration-tests.XXXXXXXX")
trap '/bin/rm -rf "$temp"' EXIT
fail() { print -u2 -- "FAIL: $*"; exit 1; }
fixture="$temp/home"; tools="$temp/tools"; control="$temp/control"; prefix="$temp/homebrew/opt/rexurrect"
mkdir -p "$fixture" "$tools" "$control" "${prefix:h}" "$temp/homebrew/Cellar/rexurrect/0.4.0-tru.1/bin"
touch "$fixture/.rexurrect-migration-test"
print -rl -- '#!/bin/zsh' 'print called > "$TEST_CONTROL/binary-called"; exit 99' > "$temp/homebrew/Cellar/rexurrect/0.4.0-tru.1/bin/rexurrect"
chmod +x "$temp/homebrew/Cellar/rexurrect/0.4.0-tru.1/bin/rexurrect"; ln -s "$temp/homebrew/Cellar/rexurrect/0.4.0-tru.1" "$prefix"
cat > "$tools/brew" <<'BREW'
#!/bin/zsh
[[ $# == 2 && "$1" == --prefix && "$2" == tru2dagame/tap/rexurrect ]] || exit 99
print -r -- "$TEST_BREW_PREFIX"
BREW
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
    [[ ! -e "$TEST_CONTROL/fail-always" ]] || exit 5
    if [[ -e "$TEST_CONTROL/fail-once" ]]; then rm "$TEST_CONTROL/fail-once"; exit 5; fi
    [[ "$(<"$TEST_CONTROL/disabled")" == 0 ]] || exit 5
    /usr/bin/plutil -extract ProgramArguments.0 raw -o "$TEST_CONTROL/program" "$3"; print 1 > "$TEST_CONTROL/loaded" ;;
  *) exit 99 ;;
esac
CTL
chmod +x "$tools/"*
run() { /usr/bin/env HOME="$fixture" PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin" REXURRECT_MIGRATION_TEST_HOME="$fixture" REXURRECT_MIGRATION_TEST_BIN="$tools" TEST_CONTROL="$control" TEST_BREW_PREFIX="$prefix" /bin/zsh "$here/migrate-legacy-install.zsh" "$@"; }
bad() { if run "$@" > "$temp/rejected.log" 2>&1; then fail 'Unexpected successful migration.'; fi; }
state="$fixture/.local/state/rexurrect-fork-manual"; config="$fixture/.config/rexurrect-fork-manual"
normal_state="$fixture/.local/state/rexurrect"; normal_config="$fixture/.config/rexurrect"
command_file="$fixture/.local/bin/rexurrect"; legacy_file="$fixture/.local/bin/rexurrect-fork"
job="$fixture/Library/LaunchAgents/io.github.cemcatik.rexurrect.autosave.plist"
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; binary="$fixture/.local/libexec/rexurrect/$commit/rexurrect"
mkdir -p "$state" "$config" "${legacy_file:h}" "${binary:h}" "${job:h}"
print synthetic-scrollback > "$state/snapshot"; print 'keep = 3' > "$config/config.toml"
cp "$temp/homebrew/Cellar/rexurrect/0.4.0-tru.1/bin/rexurrect" "$binary"
digest=$(/usr/bin/shasum -a 256 "$binary"); digest=${digest%% *}
/usr/bin/sed -E "s/^task_commit=.*/task_commit=$commit/;s/^task_expected_sha=.*/task_expected_sha=$digest/" "$here/test-fixtures/legacy-wrapper.zsh" > "$legacy_file"; chmod +x "$legacy_file"
/usr/bin/plutil -create xml1 "$job"
/usr/bin/plutil -insert Label -string io.github.cemcatik.rexurrect.autosave "$job"
/usr/bin/plutil -insert ProgramArguments -array "$job"; /usr/bin/plutil -insert ProgramArguments.0 -string "$binary" "$job"; /usr/bin/plutil -insert ProgramArguments.1 -string save "$job"
/usr/bin/plutil -insert StartInterval -integer 1234 "$job"; /usr/bin/plutil -insert EnvironmentVariables -dictionary "$job"
for key value in REX_SERVER unix://fixture.sock REXURRECT_STATE_DIR "$state" REXURRECT_CONFIG "$config/config.toml" KEEP_ENV preserve-me; do /usr/bin/plutil -insert "EnvironmentVariables.$key" -string "$value" "$job"; done
print 1 > "$control/loaded"; print 1 > "$control/disabled"; print -r -- "$binary" > "$control/program"
cp "$legacy_file" "$temp/original-command"; cp "$job" "$temp/original-job"
XDG_STATE_HOME="$fixture/other-state" bad
[[ -e "$legacy_file" && ! -L "$normal_state" && ! -L "$normal_config" ]] || fail 'Non-default environment changed the installation.'
XDG_STATE_HOME="$fixture/.local/state" XDG_CONFIG_HOME="$fixture/.config" run > "$temp/migration.log"; backup=$(sed -n 's/^Backup: //p' "$temp/migration.log")
[[ ! -e "$legacy_file" && ! -e "$command_file" && "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$job")" == "$prefix/bin/rexurrect" ]] || fail 'Command/job did not migrate to stable Homebrew opt path.'
[[ "$(/usr/bin/readlink "$normal_state")" == "$state" && "$(/usr/bin/readlink "$normal_config")" == "$config" ]] || fail 'Normal paths do not alias the original data.'
cmp "$state/snapshot" "$normal_state/snapshot"; cmp "$config/config.toml" "$normal_config/config.toml"
[[ "$(/usr/bin/plutil -extract StartInterval raw -o - "$job")" == 1234 && "$(/usr/bin/plutil -extract EnvironmentVariables.KEEP_ENV raw -o - "$job")" == preserve-me && "$(<"$control/loaded")$(<"$control/disabled")" == 11 ]] || fail 'Migration changed interval/environment/job state.'
run > "$temp/repeat.log"; grep -q 'No managed local command' "$temp/repeat.log" || fail 'Repeat was not a no-op.'
mv "$tools/brew" "$tools/brew.saved"; mv "$prefix" "$prefix.saved"
XDG_STATE_HOME="$fixture/other-state" REXURRECT_CONFIG="$fixture/other-config" run --rollback "$backup" > "$temp/rollback.log" # Recovery ignores current overrides and missing brew/opt target.
grep -q 'Original commands and autosave state restored' "$temp/rollback.log" || fail 'Rollback reported the wrong resulting state.'
mv "$tools/brew.saved" "$tools/brew"; mv "$prefix.saved" "$prefix"
cmp "$temp/original-command" "$legacy_file"; cmp "$temp/original-job" "$job"
[[ ! -e "$command_file" && ! -L "$normal_state" && ! -L "$normal_config" && "$(<"$control/loaded")$(<"$control/disabled")" == 11 ]] || fail 'Rollback changed original command names/aliases/state.'
print foreign-command > "$command_file"; bad
[[ "$(<"$command_file")" == foreign-command && -e "$legacy_file" ]] || fail 'Unknown command was overwritten.'; rm "$command_file"
mkdir "$normal_state"; print separate-data > "$normal_state/sentinel"; bad
[[ "$(<"$normal_state/sentinel")" == separate-data && -e "$legacy_file" ]] || fail 'Conflicting normal data was changed.'; rm "$normal_state/sentinel"; rmdir "$normal_state"
touch "$control/fail-once"; bad
cmp "$temp/original-command" "$legacy_file"; cmp "$temp/original-job" "$job"
[[ ! -L "$normal_state" && ! -L "$normal_config" && "$(<"$control/loaded")$(<"$control/disabled")" == 11 ]] || fail 'Failed migration did not restore files and state.'
touch "$control/fail-always"; bad
cmp "$temp/original-command" "$legacy_file"; cmp "$temp/original-job" "$job"
[[ "$(<"$control/loaded")$(<"$control/disabled")" == 01 ]] || fail 'Persistent reload failure left the job enabled.'
grep -q 'Job reload failed; recover manually' "$temp/rejected.log" || fail 'Incomplete recovery was not reported.'
rm "$control/fail-always"; print 1 > "$control/loaded"; print -r -- "$binary" > "$control/program"
# Preserve pre-existing correct aliases when rolling back this migration.
ln -s "$state" "$normal_state"; ln -s "$config" "$normal_config"
run > "$temp/preexisting.log"; preexisting=$(sed -n 's/^Backup: //p' "$temp/preexisting.log")
run --rollback "$preexisting" > "$temp/preexisting-rollback.log"
[[ -L "$normal_state" && -L "$normal_config" ]] || fail 'Rollback removed aliases it did not create.'; rm "$normal_state" "$normal_config"
/usr/bin/plutil -insert Disabled -bool true "$job"
for override expected in none 1 0 0; do
  print 0 > "$control/loaded"; print -r -- "$override" > "$control/disabled"
  run > "$temp/disabled.log"; disabled_backup=$(sed -n 's/^Backup: //p' "$temp/disabled.log")
  [[ "$(<"$disabled_backup/disabled")" == "$expected" ]] || fail 'Wrong disabled-state precedence.'
  run --rollback "$disabled_backup" > "$temp/disabled-rollback.log"
  [[ "$(<"$control/loaded")$(<"$control/disabled")" == "0$expected" ]] || fail 'Disabled-state rollback changed semantics.'
done
/usr/bin/plutil -remove Disabled "$job"; print 1 > "$control/loaded"; print 1 > "$control/disabled"; print -r -- "$binary" > "$control/program"
if /usr/bin/env HOME="$fixture" PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin" REXURRECT_MIGRATION_TEST_HOME="$fixture" REXURRECT_MIGRATION_TEST_BIN="$tools" REXURRECT_MIGRATION_TEST_FAILPOINT=before-command-removal TEST_CONTROL="$control" TEST_BREW_PREFIX="$prefix" /bin/zsh "$here/migrate-legacy-install.zsh" > "$temp/crash.log" 2>&1; then fail 'Crash test did not terminate.'; fi
[[ -e "$legacy_file" && -L "$normal_state" && "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$job")" == "$prefix/bin/rexurrect" ]] || fail 'Crash test missed migration activation.'
rmdir "$fixture/.local/libexec/rexurrect/.install-lock" # The only marked child was killed.
crash_backup=$(sed -n 's/^Backup: //p' "$temp/crash.log"); run --rollback "$crash_backup" > "$temp/crash-recovery.log"
cmp "$temp/original-command" "$legacy_file"; cmp "$temp/original-job" "$job"
[[ "$(<"$state/snapshot")" == synthetic-scrollback && "$(<"$config/config.toml")" == 'keep = 3' && ! -e "$control/binary-called" ]] || fail 'Migration touched data or ran a runtime command.'
print 'PASS: one-time Homebrew migration, stable opt path, aliases, rollback, unknown/conflicting paths, disabled precedence, reload failure and forced interruption; isolated HOME/fake brew/launchctl only.'
