#!/bin/zsh
# One-time migration of reviewed local wrappers to the normal Homebrew command.
set -euo pipefail
export LC_ALL=C
umask 077
die() { print -u2 -r -- "rexurrect migration: $*"; exit 1; }
file() { [[ -f "$1" && ! -L "$1" ]] || die "Not a regular file: $1"; }
dir() { [[ ! -L "$1" && ( ! -e "$1" || -d "$1" ) ]] || die "Unsafe directory: $1"; }
get() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }
sha() { local value; value=$(/usr/bin/shasum -a 256 "$1") || return 1; print -r -- "${value%% *}"; }
atomic_copy() { local tmp; tmp=$(/usr/bin/mktemp "$2.new.XXXXXXXX") || return 1; /bin/cp -p "$1" "$tmp" && /bin/mv -f "$tmp" "$2"; }
rollback=
if (( $# )); then [[ $# == 2 && "$1" == --rollback && -n "$2" ]] || die 'Usage: migrate-legacy-install.zsh [--rollback BACKUP]'; rollback=$2; fi
if [[ -z "$rollback" ]]; then
  [[ "${XDG_STATE_HOME:-$HOME/.local/state}" == "$HOME/.local/state" && "${XDG_CONFIG_HOME:-$HOME/.config}" == "$HOME/.config" && "${REXURRECT_STATE_DIR:-$HOME/.local/state/rexurrect}" == "$HOME/.local/state/rexurrect" && "${REXURRECT_CONFIG:-$HOME/.config/rexurrect/config.toml}" == "$HOME/.config/rexurrect/config.toml" ]] || die 'Unset non-default XDG/REXURRECT path overrides before this known-path migration.'
fi
[[ "$(/usr/bin/uname -s)" == Darwin ]] || die 'This migration uses macOS launchd.'
ctl=/bin/launchctl; brew=$(command -v brew || true)
testing=0
if [[ -n "${REXURRECT_MIGRATION_TEST_HOME:-}${REXURRECT_MIGRATION_TEST_BIN:-}" ]]; then
  test_home=${REXURRECT_MIGRATION_TEST_HOME:-invalid}
  [[ -n "${REXURRECT_MIGRATION_TEST_BIN:-}" && "${HOME:A}" == "${test_home:A}" && -f "$HOME/.rexurrect-migration-test" ]] || die 'Test tools require a marked isolated HOME.'
  testing=1; ctl="$REXURRECT_MIGRATION_TEST_BIN/launchctl"; brew="$REXURRECT_MIGRATION_TEST_BIN/brew"
fi
[[ -x "$ctl" ]] || die 'Missing launchctl.'
brew_binary=
if [[ -z "$rollback" ]]; then
  [[ -x "$brew" ]] || die 'Install Homebrew and tru2dagame/tap/rexurrect first.'
  prefix=$("$brew" --prefix tru2dagame/tap/rexurrect)
  [[ "$prefix" == /*/opt/rexurrect && -x "$prefix/bin/rexurrect" ]] || die 'Install tru2dagame/tap/rexurrect first; expected its stable opt path.'
  brew_binary="$prefix/bin/rexurrect" # Keep opt, never resolve this to a Cellar version.
fi
root="$HOME/.local/libexec/rexurrect"; command_file="$HOME/.local/bin/rexurrect"; legacy_file="$HOME/.local/bin/rexurrect-fork"
normal_state="$HOME/.local/state/rexurrect"; normal_config="$HOME/.config/rexurrect"
legacy_state="$HOME/.local/state/rexurrect-fork-manual"; legacy_config="$HOME/.config/rexurrect-fork-manual"
job="$HOME/Library/LaunchAgents/io.github.cemcatik.rexurrect.autosave.plist"
service="gui/$(/usr/bin/id -u)/io.github.cemcatik.rexurrect.autosave"; domain=${service:h}
stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}rexurrect-migration.XXXXXXXX"); locked=0 changing=0 backup=
owned=(); [[ -z "$brew_binary" ]] || owned+=("$brew_binary"); layout=
read_wrapper() {
  local source=$1 digest pin version
  file "$source"
  digest=$(/usr/bin/sed -E 's/^task_commit=[0-9a-f]{40}$/task_commit=COMMIT/;s/^task_version=v[0-9]+\.[0-9]+\.[0-9]+-tru\.[0-9]+$/task_version=VERSION/;s/^task_expected_sha=[0-9a-f]{64}$/task_expected_sha=SHA/' "$source" | /usr/bin/shasum -a 256)
  case "${digest%% *}" in
    50e73edd55dd4184399c3a1c85deb9330399b560ef3f343dc4c2beb125970909|b647fb453200636df40d4de2d54660e302aab9701cc0c1f28318f4dcfa6db90f|69175271e7968e614a925e8e05fdf9ce478e4eb7360113c139c355eeef721942) selected_layout=legacy ;;
    0f0b2e79973f96343e1d3e28beb8b158d414b38e8e9a564ddf6ee660b6af5fec) selected_layout=normal ;;
    *) die "Unknown local command; refusing removal: $source" ;;
  esac
  pin=$(/usr/bin/sed -n 's/^task_expected_sha=//p' "$source")
  version=$(/usr/bin/sed -n -E 's/^task_(commit|version)=//p' "$source")
  selected="$root/$version/rexurrect"; file "$selected"; [[ ! -L "${selected:h}" && -x "$selected" && "$(sha "$selected")" == "$pin" ]] || die 'Pinned legacy binary checksum mismatch.'
  [[ -z "$layout" || "$layout" == "$selected_layout" ]] || die 'Conflicting normal and legacy installations.'
  layout=$selected_layout; owned+=("$selected")
}
check_job() {
  local source=$1 program key line found=0
  file "$source"; /usr/bin/plutil -convert xml1 -o "$stage/schema.plist" "$source"
  while IFS= read -r line; do
    if [[ "$line" == $'\t<key>'* ]]; then key=${line#$'\t<key>'}; key=${key%</key>}; case "$key" in Label|ProgramArguments|StartInterval|ProcessType|StandardOutPath|StandardErrorPath|EnvironmentVariables|Disabled) ;; *) die "Unknown autosave field: $key" ;; esac; fi
  done < "$stage/schema.plist"
  program=$(get "$source" ProgramArguments.0)
  for key in "${owned[@]}"; do [[ "$program" != "$key" ]] || found=1; done
  [[ "$found" == 1 && "$(get "$source" Label)" == io.github.cemcatik.rexurrect.autosave && "$(get "$source" ProgramArguments)" == 2 && "$(get "$source" ProgramArguments.1)" == save && "$(get "$source" StartInterval)" =~ '^[1-9][0-9]*$' ]] || die 'Autosave belongs to another installation.'
  [[ "$(get "$source" EnvironmentVariables.REXURRECT_STATE_DIR)" == "$state" && "$(get "$source" EnvironmentVariables.REXURRECT_CONFIG)" == "$config_dir/config.toml" && -n "$(get "$source" EnvironmentVariables.REX_SERVER)" ]] || die 'Autosave state/config/endpoint differs.'
}
reload_job() {
  local failed=0
  if [[ "$1" == 1 ]]; then "$ctl" enable "$service" && "$ctl" bootstrap "$domain" "$job" || failed=1; fi
  if [[ "$2" == 1 ]]; then "$ctl" disable "$service"; else "$ctl" enable "$service"; fi || failed=1
  return "$failed"
}
remove_alias() {
  if [[ -L "$1" && "$(/usr/bin/readlink "$1")" == "$2" ]]; then /bin/rm "$1"
  else [[ ! -e "$1" && ! -L "$1" ]]; fi
}
restore_files() {
  if [[ "$(<"$backup/had_job")" == 1 ]]; then atomic_copy "$backup/autosave.plist" "$job" || return 1; else /bin/rm -f "$job" || return 1; fi
  if [[ "$(<"$backup/had_command")" == 1 ]]; then atomic_copy "$backup/command" "$command_file" || return 1; fi
  if [[ "$(<"$backup/had_legacy")" == 1 ]]; then atomic_copy "$backup/legacy-command" "$legacy_file" || return 1; fi
  if [[ "$(<"$backup/had_command")" == 0 ]]; then /bin/rm -f "$command_file" || return 1; fi
  if [[ "$(<"$backup/had_legacy")" == 0 ]]; then /bin/rm -f "$legacy_file" || return 1; fi
  if [[ "$(<"$backup/made_config")" == 1 ]]; then remove_alias "$normal_config" "$legacy_config" || return 1; fi
  if [[ "$(<"$backup/made_state")" == 1 ]]; then remove_alias "$normal_state" "$legacy_state" || return 1; fi
}
cleanup() {
  local result=$?; trap - EXIT HUP INT TERM; set +e
  if (( changing )); then
    "$ctl" bootout "$service" >/dev/null 2>&1
    if restore_files; then reload_job "$(<"$backup/loaded")" "$(<"$backup/disabled")" || print -u2 -- "Job reload failed; recover manually from $backup"
    else print -u2 -- "File recovery failed; recover manually from $backup"; fi
  fi
  (( locked )) && /bin/rmdir "$root/.install-lock" 2>/dev/null
  /bin/rm -rf "$stage"; return $result
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' HUP TERM
for path_dir in "$HOME/.local" "$HOME/.local/bin" "$HOME/.local/libexec" "$root" "$HOME/.local/state" "$HOME/.config" "$HOME/Library" "$HOME/Library/LaunchAgents"; do dir "$path_dir"; done
/bin/mkdir -p "$root" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
/bin/mkdir "$root/.install-lock" 2>/dev/null || die 'Install lock exists; inspect the previous process before retrying.'; locked=1
had_command=0 had_legacy=0 had_job=0 loaded=0 disabled=0 made_state=0 made_config=0
if [[ -e "$command_file" || -L "$command_file" ]]; then read_wrapper "$command_file"; had_command=1; fi
if [[ -e "$legacy_file" || -L "$legacy_file" ]]; then read_wrapper "$legacy_file"; had_legacy=1; fi
if [[ -n "$rollback" ]]; then
  dir "$legacy_state"
  if [[ ! -L "$normal_state" || "$(/usr/bin/readlink "$normal_state")" != "$legacy_state" ]]; then dir "$normal_state"; fi
  dir "$legacy_state/migration-backups"; dir "$normal_state/migration-backups"
  backup=${rollback:A}; parent=${backup:h}
  legacy_backups="$legacy_state/migration-backups"; normal_backups="$normal_state/migration-backups"
  [[ ! -L "$rollback" && ( "$parent" == "${legacy_backups:A}" || "$parent" == "${normal_backups:A}" ) ]] || die 'Select an owned migration-backups directory.'
  file "$backup/marker"; [[ "$(<"$backup/marker")" == rexurrect-homebrew-migration-v1 ]] || die 'Unknown migration backup.'
  file "$backup/homebrew-binary"; brew_binary=$(<"$backup/homebrew-binary")
  [[ "$brew_binary" == /*/opt/rexurrect/bin/rexurrect ]] || die 'Invalid saved Homebrew command.'; owned+=("$brew_binary")
  for flag in had_command had_legacy had_job loaded disabled made_state made_config; do file "$backup/$flag"; [[ "$(<"$backup/$flag")" == [01] ]] || die 'Invalid backup flags.'; done
  file "$backup/layout"; saved_layout=$(<"$backup/layout"); [[ "$saved_layout" == legacy || "$saved_layout" == normal ]] || die 'Invalid backup layout.'
  [[ -z "$layout" || "$layout" == "$saved_layout" ]] || die 'Backup layout differs.'; layout=$saved_layout
  if [[ "$(<"$backup/had_command")" == 1 ]]; then read_wrapper "$backup/command"; fi
  if [[ "$(<"$backup/had_legacy")" == 1 ]]; then read_wrapper "$backup/legacy-command"; fi
  [[ "$(<"$backup/loaded")" == 0 || "$(<"$backup/had_job")" == 1 ]] || die 'Backup cannot load a missing job.'
elif (( ! had_command && ! had_legacy )); then
  [[ ! -e "$job" || "$(get "$job" ProgramArguments.0)" == "$brew_binary" ]] || die 'Autosave has no recognized legacy command.'
  print 'No managed local command remains; use the normal Homebrew command.'; exit 0
fi
if [[ "$layout" == legacy ]]; then state=$legacy_state; config_dir=$legacy_config; else state=$normal_state; config_dir=$normal_config; fi
dir "$state"; dir "$config_dir"
if [[ -z "$rollback" && "$layout" == legacy ]]; then
  for target source flag in "$normal_state" "$legacy_state" made_state "$normal_config" "$legacy_config" made_config; do
    if [[ -L "$target" && "$(/usr/bin/readlink "$target")" == "$source" ]]; then :
    else [[ ! -e "$target" && ! -L "$target" ]] || die "Conflicting normal path: $target"; typeset "$flag=1"; fi
  done
fi
if loaded_text=$($ctl print "$service" 2>/dev/null); then loaded=1; [[ "$loaded_text" != *'state = running'* ]] || die 'Autosave is running; retry after it finishes.'; fi
disabled_text=$($ctl print-disabled "$domain"); disabled_override=0
if print -r -- "$disabled_text" | /usr/bin/grep -F '"io.github.cemcatik.rexurrect.autosave" => true' >/dev/null; then disabled=1; disabled_override=1
elif print -r -- "$disabled_text" | /usr/bin/grep -F '"io.github.cemcatik.rexurrect.autosave" => false' >/dev/null; then disabled_override=1; fi
if [[ -e "$job" || -L "$job" ]]; then
  check_job "$job"; had_job=1
  if (( ! disabled_override )) && [[ "$(get "$job" Disabled 2>/dev/null)" == true ]]; then disabled=1; fi
  if (( loaded )); then [[ "$(print -r -- "$loaded_text" | /usr/bin/sed -n 's/^[[:space:]]*program = //p')" == "$(get "$job" ProgramArguments.0)" ]] || die 'Loaded job and plist disagree.'; fi
elif (( loaded )); then die 'Loaded autosave has no owned plist.'; fi
if [[ -n "$rollback" ]]; then
  if [[ "$(<"$backup/had_job")" == 1 ]]; then check_job "$backup/autosave.plist"; fi
  for target source flag in "$normal_state" "$legacy_state" made_state "$normal_config" "$legacy_config" made_config; do
    if [[ "$(<"$backup/$flag")" == 1 && ( -e "$target" || -L "$target" ) ]]; then [[ -L "$target" && "$(/usr/bin/readlink "$target")" == "$source" ]] || die "Changed alias: $target"; fi
  done
else
  dir "$state/migration-backups"; /bin/mkdir -p "$state/migration-backups"
  backup=$(/usr/bin/mktemp -d "$state/migration-backups/$(/bin/date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
  print rexurrect-homebrew-migration-v1 > "$backup/marker"; print -r -- "$layout" > "$backup/layout"
  print -r -- "$brew_binary" > "$backup/homebrew-binary"
  for flag in had_command had_legacy had_job loaded disabled made_state made_config; do print -r -- "${(P)flag}" > "$backup/$flag"; done
  (( had_command )) && /bin/cp -p "$command_file" "$backup/command"
  (( had_legacy )) && /bin/cp -p "$legacy_file" "$backup/legacy-command"
  (( had_job )) && /bin/cp -p "$job" "$backup/autosave.plist"
fi
print -r -- "Backup: $backup"
changing=1
(( loaded )) && "$ctl" bootout "$service"
if [[ -n "$rollback" ]]; then
  restore_files || die "Cannot restore files; retry from $backup"
  reload_job "$(<"$backup/loaded")" "$(<"$backup/disabled")" || die "Cannot restore job; retry from $backup"
else
  if [[ "$layout" == legacy ]]; then
    /bin/mkdir -p "$legacy_config"
    (( ! made_state )) || /bin/ln -s "$legacy_state" "$normal_state"
    (( ! made_config )) || /bin/ln -s "$legacy_config" "$normal_config"
  fi
  if (( had_job )); then
    /bin/cp "$job" "$stage/new-job.plist"; /usr/bin/plutil -remove ProgramArguments "$stage/new-job.plist"
    /usr/bin/plutil -insert ProgramArguments -array "$stage/new-job.plist"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$brew_binary" "$stage/new-job.plist"
    /usr/bin/plutil -insert ProgramArguments.1 -string save "$stage/new-job.plist"
    atomic_copy "$stage/new-job.plist" "$job" || die 'Cannot replace autosave plist.'
    reload_job "$loaded" "$disabled" || die 'Cannot reload autosave.'
  fi
  if (( testing )) && [[ "${REXURRECT_MIGRATION_TEST_FAILPOINT:-}" == before-command-removal ]]; then /bin/kill -KILL $$; fi
  (( ! had_command )) || /bin/rm "$command_file"
  (( ! had_legacy )) || /bin/rm "$legacy_file"
fi
changing=0
if [[ -n "$rollback" ]]; then print 'Completed. Original commands and autosave state restored; Homebrew package unchanged.'
else print 'Completed. Use Homebrew rexurrect; old binaries/data remain intact. No save, restore, or Rex restart was run.'; fi
