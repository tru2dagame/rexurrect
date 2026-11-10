#!/bin/zsh
# Explicit-version installer for the standard cargo-dist macOS arm64 archive.
set -euo pipefail
export LC_ALL=C
umask 077
die() { print -u2 -r -- "rexurrect: $*"; exit 1; }
get() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }
sha() { local value=$(/usr/bin/shasum -a 256 "$1"); print -r -- "${value%% *}"; }
file() { [[ -f "$1" && ! -L "$1" ]] || die "Not a regular file: $1"; }
tag_ok() { [[ "$1" =~ '^v[0-9]+\.[0-9]+\.[0-9]+-tru\.[0-9]+$' ]]; }
atomic_copy() { local tmp; tmp=$(/usr/bin/mktemp "$2.new.XXXXXXXX") || return 1; /bin/cp -p "$1" "$tmp" && /bin/mv -f "$tmp" "$2"; }
version= archive= digest= rollback= autosave=0
while (( $# )); do
  case "$1" in
    --version|--archive|--sha256|--rollback)
      (( $# > 1 )) || die "Missing value after $1"
      case "$1" in --version) version=$2 ;; --archive) archive=$2 ;; --sha256) digest=$2 ;; --rollback) rollback=$2 ;; esac
      shift 2 ;;
    --autosave) autosave=1; shift ;;
    *) die 'Usage: install.zsh --version <vTAG> [--autosave] [--archive FILE --sha256 SHA] | --rollback BACKUP' ;;
  esac
done
if [[ -n "$rollback" ]]; then [[ -z "$version$archive$digest" && $autosave == 0 ]] || die 'Rollback takes only its backup directory.'
else tag_ok "$version" || die 'Select an explicit tag, for example v0.4.0-tru.1.'; fi
[[ -z "$archive" && -z "$digest" || -n "$archive" && "$digest" =~ '^[0-9a-f]{64}$' ]] || die 'Local --archive requires its --sha256.'
[[ "$(/usr/bin/uname -s)" == Darwin && "$(/usr/sbin/sysctl -n hw.optional.arm64)" == 1 ]] || die 'Apple Silicon macOS is required.'
ctl=/bin/launchctl curl=/usr/bin/curl sign=/usr/bin/codesign lipo=/usr/bin/lipo testing=0
if [[ -n "${REXURRECT_INSTALL_TEST_BIN:-}${REXURRECT_INSTALL_TEST_HOME:-}" ]]; then
  test_home=${REXURRECT_INSTALL_TEST_HOME:-invalid}
  [[ -n "${REXURRECT_INSTALL_TEST_BIN:-}" && "${HOME:A}" == "${test_home:A}" && -f "$HOME/.rexurrect-install-test" ]] || die 'Test tools require a marked isolated HOME.'
  testing=1; ctl="$REXURRECT_INSTALL_TEST_BIN/launchctl"; curl="$REXURRECT_INSTALL_TEST_BIN/curl"; sign="$REXURRECT_INSTALL_TEST_BIN/codesign"; lipo="$REXURRECT_INSTALL_TEST_BIN/lipo"
  for tool in "$ctl" "$curl" "$sign" "$lipo"; do file "$tool"; [[ -x "$tool" ]] || die "Not executable: $tool"; done
fi
root="$HOME/.local/libexec/rexurrect"; wrapper="$HOME/.local/bin/rexurrect"; legacy_wrapper="$HOME/.local/bin/rexurrect-fork"
job="$HOME/Library/LaunchAgents/io.github.cemcatik.rexurrect.autosave.plist"
label=io.github.cemcatik.rexurrect.autosave; domain="gui/$(/usr/bin/id -u)"; service="$domain/$label"
stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}rexurrect-install.XXXXXXXX"); locked=0 changing=0 backup=
make_wrapper() {
  local suffix=; [[ "$4" != legacy ]] || suffix=-fork-manual
  { print -rl -- '#!/bin/zsh' '# Self-contained, checksum-pinned Rexurrect.' 'set -euo pipefail' "task_version=$1" "task_expected_sha=$2"
    /bin/cat <<'WRAPPER'
task_binary="$HOME/.local/libexec/rexurrect/$task_version/rexurrect"
[[ -x "$task_binary" && ! -L "$task_binary" ]] || { print -u2 -- "Missing pinned binary: $task_binary"; exit 1; }
task_actual=$(/usr/bin/shasum -a 256 "$task_binary")
[[ "${task_actual%% *}" == "$task_expected_sha" ]] || { print -u2 -- 'Pinned binary checksum mismatch.'; exit 1; }
export REX_SERVER="${REX_SERVER:-unix://$HOME/Library/Application%20Support/rex/server.sock}"
WRAPPER
    print -rl -- 'export REXURRECT_STATE_DIR="$HOME/.local/state/rexurrect'"$suffix"'"' 'export REXURRECT_CONFIG="$HOME/.config/rexurrect'"$suffix"'/config.toml"'
    /bin/cat <<'WRAPPER'
task_rex="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
if [[ -x "$task_rex" ]]; then export PATH="${task_rex:h}:$PATH"; fi
if [[ "${1:-}" == --build-info ]]; then
  print -r -- "Release: $task_version" "Binary SHA-256: $task_expected_sha" "Binary: $task_binary" "Rex endpoint: $REX_SERVER" "Snapshot state: $REXURRECT_STATE_DIR" "Config: $REXURRECT_CONFIG"
  exit 0
fi
if (( $# == 0 )); then set -- help; fi
exec "$task_binary" "$@"
WRAPPER
  } > "$3"
}
read_wrapper() {
  local wrapper_file=$1 version_id hash_id normal
  file "$wrapper_file"
  version_id=$(/usr/bin/sed -n 's/^task_version=//p' "$wrapper_file")
  hash_id=$(/usr/bin/sed -n 's/^task_expected_sha=//p' "$wrapper_file")
  [[ "$hash_id" =~ '^[0-9a-f]{64}$' ]] || die 'Unknown wrapper checksum field.'
  selected_layout=legacy
  if tag_ok "$version_id"; then
    normal=$(/usr/bin/sed -E 's/^task_version=v[0-9]+\.[0-9]+\.[0-9]+-tru\.[0-9]+$/task_version=VERSION/;s/^task_expected_sha=[0-9a-f]{64}$/task_expected_sha=SHA/' "$wrapper_file" | /usr/bin/shasum -a 256)
    if [[ "$version_id" != v0.4.0-tru.1 || "${normal%% *}" != b647fb453200636df40d4de2d54660e302aab9701cc0c1f28318f4dcfa6db90f ]]; then
      selected_layout=normal; make_wrapper "$version_id" "$hash_id" "$stage/canonical-wrapper" normal
      if ! /usr/bin/cmp -s "$wrapper_file" "$stage/canonical-wrapper"; then
        selected_layout=legacy; make_wrapper "$version_id" "$hash_id" "$stage/canonical-wrapper" legacy
        /usr/bin/cmp -s "$wrapper_file" "$stage/canonical-wrapper" || die 'Existing wrapper was modified.'
      fi
    fi
  else
    normal=$(/usr/bin/sed -E 's/^task_commit=[0-9a-f]{40}$/task_commit=COMMIT/;s/^task_expected_sha=[0-9a-f]{64}$/task_expected_sha=SHA/' "$wrapper_file" | /usr/bin/shasum -a 256)
    [[ "${normal%% *}" == 50e73edd55dd4184399c3a1c85deb9330399b560ef3f343dc4c2beb125970909 ]] || die 'Unknown existing wrapper; refusing replacement.'
    version_id=$(/usr/bin/sed -n 's/^task_commit=//p' "$wrapper_file")
  fi
  selected="$root/$version_id/rexurrect"; [[ ! -L "${selected:h}" ]] || die 'Pinned version directory is a symlink.'; file "$selected"
  [[ -x "$selected" && "$(sha "$selected")" == "$hash_id" ]] || die 'Existing pinned binary checksum mismatch.'
}
check_job() {
  local source=$1 expected=$2 key line interval
  file "$source"; /usr/bin/plutil -convert xml1 -o "$stage/schema.plist" "$source"
  while IFS= read -r line; do
    if [[ "$line" == $'\t<key>'* ]]; then
      key=${line#$'\t<key>'}; key=${key%</key>}
      case "$key" in Label|ProgramArguments|StartInterval|ProcessType|StandardOutPath|StandardErrorPath|EnvironmentVariables|Disabled) ;; *) die "Unknown autosave field: $key" ;; esac
    fi
  done < "$stage/schema.plist"
  interval=$(get "$source" StartInterval)
  [[ "$(get "$source" Label)" == "$label" && "$(get "$source" ProgramArguments)" == 2 && "$(get "$source" ProgramArguments.0)" == "$expected" && "$(get "$source" ProgramArguments.1)" == save && "$interval" =~ '^[1-9][0-9]*$' ]] || die 'Autosave belongs to another installation.'
  [[ "$(get "$source" EnvironmentVariables.REXURRECT_STATE_DIR)" == "$state" && "$(get "$source" EnvironmentVariables.REXURRECT_CONFIG)" == "$config" && -n "$(get "$source" EnvironmentVariables.REX_SERVER)" ]] || die 'Autosave state/config/endpoint differs; review the migration.'
}
reload_job() {
  local failed=0
  if [[ "$1" == 1 ]]; then "$ctl" enable "$service" && "$ctl" bootstrap "$domain" "$job" || failed=1; fi
  if [[ "$2" == 1 ]]; then "$ctl" disable "$service"; else "$ctl" enable "$service"; fi || failed=1
  return "$failed"
}
restore_files() {
  local from=$1
  if [[ "$(<"$from/had_job")" == 1 ]]; then atomic_copy "$from/autosave.plist" "$job" || return 1; else /bin/rm -f "$job" || return 1; fi
  if [[ "$(<"$from/marker")" == rexurrect-fork-backup-v1 ]]; then
    if [[ "$(<"$from/had_wrapper")" == 1 ]]; then atomic_copy "$from/wrapper" "$legacy_wrapper" || return 1; else /bin/rm -f "$legacy_wrapper" || return 1; fi
    /bin/rm -f "$wrapper" || return 1
  else
    if [[ "$(<"$from/had_legacy")" == 1 ]]; then atomic_copy "$from/legacy-wrapper" "$legacy_wrapper" || return 1; fi
    if (( testing )) && [[ "${REXURRECT_INSTALL_TEST_FAILPOINT:-}" == during-command-restore ]]; then /bin/kill -KILL $$; fi
    if [[ "$(<"$from/had_wrapper")" == 1 ]]; then atomic_copy "$from/wrapper" "$wrapper" || return 1; fi
    if [[ "$(<"$from/had_legacy")" == 0 ]]; then /bin/rm -f "$legacy_wrapper" || return 1; fi
    if [[ "$(<"$from/had_wrapper")" == 0 ]]; then /bin/rm -f "$wrapper" || return 1; fi
  fi
}
cleanup() {
  local result=$?; trap - EXIT HUP INT TERM; set +e
  if (( changing )); then
    print -u2 -- "Failed; restoring files and job from $backup"
    "$ctl" bootout "$service" >/dev/null 2>&1
    if restore_files "$backup"; then reload_job "$(<"$backup/loaded")" "$(<"$backup/disabled")" || print -u2 -- "Job reload failed; recover manually from $backup"
    else print -u2 -- "File recovery failed; recover manually from $backup"; fi
  fi
  (( locked )) && /bin/rmdir "$root/.install-lock" 2>/dev/null
  /bin/rm -rf "$stage"; return $result
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' HUP TERM
if [[ -z "$rollback" ]]; then
  asset=rexurrect-aarch64-apple-darwin.tar.xz; prefix=rexurrect-aarch64-apple-darwin
  if [[ -z "$archive" ]]; then
    base="https://github.com/tru2dagame/rexurrect/releases/download/$version"
    "$curl" --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$base/$asset.sha256" -o "$stage/checksum"
    line=$(<"$stage/checksum")
    [[ "$line" =~ '^([0-9a-f]{64}) [ *]rexurrect-aarch64-apple-darwin\.tar\.xz[[:space:]]*$' ]] || die 'Malformed cargo-dist checksum.'
    digest=${match[1]}
    "$curl" --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$base/$asset" -o "$stage/archive.tar.xz"
  else file "$archive"; /bin/cp "$archive" "$stage/archive.tar.xz"; fi
  [[ "$(sha "$stage/archive.tar.xz")" == "$digest" ]] || die 'Archive SHA-256 mismatch.'
  /usr/bin/tar -tf "$stage/archive.tar.xz" > "$stage/names"; names=(); binary_count=0
  while IFS= read -r name; do
    case "$name" in
      "$prefix/"|"$prefix/LICENSE"|"$prefix/README.md"|"$prefix/rexurrect.plugin.zsh"|"$prefix/install.zsh"|"$prefix/install-fork.zsh") ;;
      "$prefix/rexurrect") (( binary_count += 1 )) ;;
      *) die "Unexpected archive path: $name" ;;
    esac
    names+=("$name")
  done < "$stage/names"
  [[ "$binary_count" == 1 && ${#names} == ${#${(u)names}} ]] || die 'Missing binary or duplicate archive entries.'
  /usr/bin/tar -tvf "$stage/archive.tar.xz" > "$stage/types"
  while IFS= read -r line; do [[ "$line" == -* || "$line" == d* && "$line" == *"$prefix/" ]] || die 'Archive contains a link or non-regular file.'; done < "$stage/types"
  /usr/bin/tar -xf "$stage/archive.tar.xz" -C "$stage" "$prefix/rexurrect"
  candidate="$stage/$prefix/rexurrect"; file "$candidate"
  "$sign" --verify --strict "$candidate"
  [[ "$($lipo -archs "$candidate")" == arm64 && "$("$candidate" --version)" == "rexurrect ${version#v}" ]] || die 'Binary architecture/version does not match the selected release.'
  binary_sha=$(sha "$candidate")
fi
for directory in "$HOME/.local" "$HOME/.local/bin" "$HOME/.local/libexec" "$root" "$HOME/.local/state" "$HOME/Library" "$HOME/Library/LaunchAgents"; do
  [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || die "Unsafe directory: $directory"
done
/bin/mkdir -p "$root" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
/bin/mkdir "$root/.install-lock" 2>/dev/null || die 'Install lock exists; finish or inspect the previous installation before retrying.'; locked=1
old_binary= legacy_binary= had_wrapper=0 had_legacy=0 had_job=0 loaded=0 disabled=0 layout=normal
if [[ -e "$wrapper" || -L "$wrapper" ]]; then read_wrapper "$wrapper"; old_binary=$selected; layout=$selected_layout; had_wrapper=1; fi
if [[ -e "$legacy_wrapper" || -L "$legacy_wrapper" ]]; then
  read_wrapper "$legacy_wrapper"; [[ "$selected_layout" == legacy && ( "$had_wrapper" == 0 || "$layout" == legacy ) ]] || die 'Conflicting normal and legacy installations.'
  legacy_binary=$selected; layout=legacy; had_legacy=1; [[ -n "$old_binary" ]] || old_binary=$selected
fi
if [[ -n "$rollback" && "$had_wrapper$had_legacy" == 00 && "${rollback:A:h}" == "$HOME/.local/state/rexurrect-fork-manual/install-backups" ]]; then layout=legacy; fi
suffix=; [[ "$layout" != legacy ]] || suffix=-fork-manual
state="$HOME/.local/state/rexurrect$suffix"; config="$HOME/.config/rexurrect$suffix/config.toml"; backups="$state/install-backups"
for directory in "$state" "$backups"; do [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || die "Unsafe directory: $directory"; done
/bin/mkdir -p "$backups"
[[ -n "$rollback" ]] || make_wrapper "$version" "$binary_sha" "$stage/new-wrapper" "$layout"
rollback_binary= backup_legacy_binary=
if [[ -n "$rollback" ]]; then
  [[ "${rollback:A:h}" == "${backups:A}" && ! -L "$rollback" ]] || die 'Select an owned install-backups directory.'
  for name in marker had_wrapper had_job loaded disabled; do file "$rollback/$name"; done
  backup_marker=$(<"$rollback/marker")
  [[ "$backup_marker" == rexurrect-backup-v2 || "$backup_marker" == rexurrect-fork-backup-v1 ]] || die 'Unknown backup.'
  for name in had_wrapper had_job loaded disabled; do [[ "$(<"$rollback/$name")" == [01] ]] || die 'Invalid backup flags.'; done
  if [[ "$backup_marker" == rexurrect-backup-v2 ]]; then
    file "$rollback/had_legacy"; [[ "$(<"$rollback/had_legacy")" == [01] ]] || die 'Invalid legacy command flag.'
    if [[ "$(<"$rollback/had_legacy")" == 1 ]]; then read_wrapper "$rollback/legacy-wrapper"; [[ "$selected_layout" == "$layout" ]] || die 'Backup layout differs.'; rollback_binary=$selected; backup_legacy_binary=$selected; fi
  else [[ "$layout" == legacy ]] || die 'Invalid legacy backup'; fi
  [[ "$(<"$rollback/loaded")" == 0 || "$(<"$rollback/had_job")" == 1 ]] || die 'Backup cannot load a missing job.'
  if [[ "$(<"$rollback/had_wrapper")" == 1 ]]; then read_wrapper "$rollback/wrapper"; [[ "$selected_layout" == "$layout" ]] || die 'Backup layout differs.'; rollback_binary=$selected; fi
  if [[ "$(<"$rollback/had_job")" == 1 ]]; then
    [[ -n "$rollback_binary" ]] || die 'Invalid backup job'; backup_job_binary=$(get "$rollback/autosave.plist" ProgramArguments.0)
    [[ "$backup_job_binary" == "$rollback_binary" || -n "$backup_legacy_binary" && "$backup_job_binary" == "$backup_legacy_binary" ]] || die 'Backup job has no matching command.'
    check_job "$rollback/autosave.plist" "$backup_job_binary"; rollback_binary=$backup_job_binary
  fi
fi
if loaded_text=$($ctl print "$service" 2>/dev/null); then loaded=1; [[ "$loaded_text" != *'state = running'* ]] || die 'Autosave is running; retry after it finishes.'; fi
disabled_text=$($ctl print-disabled "$domain")
disabled_override=0
if print -r -- "$disabled_text" | /usr/bin/grep -F '"io.github.cemcatik.rexurrect.autosave" => true' >/dev/null; then disabled=1; disabled_override=1
elif print -r -- "$disabled_text" | /usr/bin/grep -F '"io.github.cemcatik.rexurrect.autosave" => false' >/dev/null; then disabled_override=1; fi
if [[ -e "$job" || -L "$job" ]]; then
  (( had_wrapper || had_legacy )) || die 'Autosave has no recognized wrapper.'
  job_binary=$(get "$job" ProgramArguments.0)
  [[ "$job_binary" == "$old_binary" || -n "$legacy_binary" && "$job_binary" == "$legacy_binary" || -n "$rollback_binary" && "$job_binary" == "$rollback_binary" ]] || die 'Autosave is not owned by the current or selected backup binary.'
  check_job "$job" "$job_binary"; had_job=1
  if (( ! disabled_override )) && [[ "$(get "$job" Disabled 2>/dev/null)" == true ]]; then disabled=1; fi
  if (( loaded )); then [[ "$(print -r -- "$loaded_text" | /usr/bin/sed -n 's/^[[:space:]]*program = //p')" == "$job_binary" ]] || die 'Loaded job and plist disagree.'; fi
elif (( loaded )); then die 'Loaded autosave has no owned plist.'; fi
if [[ -z "$rollback" && "$had_wrapper$had_legacy" == 10 ]] && /usr/bin/cmp -s "$wrapper" "$stage/new-wrapper" && (( had_job || ! autosave )); then
  print -r -- "Already installed $version; autosave is unchanged."; exit 0
fi
backup=$(/usr/bin/mktemp -d "$backups/$(/bin/date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
print -r -- rexurrect-backup-v2 > "$backup/marker"
for name in had_wrapper had_legacy had_job loaded disabled; do print -r -- "${(P)name}" > "$backup/$name"; done
(( had_wrapper )) && /bin/cp -p "$wrapper" "$backup/wrapper"
(( had_legacy )) && /bin/cp -p "$legacy_wrapper" "$backup/legacy-wrapper"
(( had_job )) && /bin/cp -p "$job" "$backup/autosave.plist"
print -r -- "Backup: $backup"
if [[ -z "$rollback" ]]; then
  destination="$root/$version"; [[ ! -L "$destination" ]] || die 'Version directory is a symlink.'
  [[ ! -e "$destination" || -d "$destination" ]] || die 'Version path is not a directory.'; /bin/mkdir -p "$destination"
  if [[ -e "$destination/rexurrect" || -L "$destination/rexurrect" ]]; then file "$destination/rexurrect"; [[ "$(sha "$destination/rexurrect")" == "$binary_sha" ]] || die 'Installed tag has different bytes.'
  else /usr/bin/install -m 0555 "$candidate" "$destination/.rexurrect.$$"; /bin/mv "$destination/.rexurrect.$$" "$destination/rexurrect"; fi
  /bin/chmod 0755 "$stage/new-wrapper"
fi
changing=1
(( loaded )) && "$ctl" bootout "$service"
if [[ -n "$rollback" ]]; then restore_files "$rollback" || die 'Cannot restore backup files.'; reload_job "$(<"$rollback/loaded")" "$(<"$rollback/disabled")" || die 'Cannot reload the selected backup job.'
else
  atomic_copy "$stage/new-wrapper" "$wrapper" || die 'Cannot replace wrapper.'
  if (( testing )) && [[ "${REXURRECT_INSTALL_TEST_FAILPOINT:-}" == after-wrapper ]]; then /bin/kill -KILL $$; fi
  (( ! had_legacy )) || /bin/rm -f "$legacy_wrapper"
  if (( had_job )); then
    /bin/cp "$job" "$stage/new-job.plist"; /usr/bin/plutil -remove ProgramArguments "$stage/new-job.plist"
  elif (( autosave )); then
    /usr/bin/plutil -create xml1 "$stage/new-job.plist"
    /usr/bin/plutil -insert Label -string "$label" "$stage/new-job.plist"
    /usr/bin/plutil -insert StartInterval -integer 900 "$stage/new-job.plist"
    /usr/bin/plutil -insert EnvironmentVariables -dictionary "$stage/new-job.plist"
    for name value in PATH /usr/bin:/bin:/usr/sbin:/sbin REX_SERVER "unix://$HOME/Library/Application%20Support/rex/server.sock" REXURRECT_STATE_DIR "$state" REXURRECT_CONFIG "$config"; do /usr/bin/plutil -insert "EnvironmentVariables.$name" -string "$value" "$stage/new-job.plist"; done
  fi
  if [[ -f "$stage/new-job.plist" ]]; then
    /usr/bin/plutil -insert ProgramArguments -array "$stage/new-job.plist"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$root/$version/rexurrect" "$stage/new-job.plist"
    /usr/bin/plutil -insert ProgramArguments.1 -string save "$stage/new-job.plist"
    atomic_copy "$stage/new-job.plist" "$job" || die 'Cannot replace autosave plist.'
    if (( loaded || ! had_job && autosave )); then reload_job 1 "$(( had_job ? disabled : 0 ))" || die 'Cannot reload autosave.'; fi
  fi
fi
changing=0
print -r -- "Completed. Command: $wrapper" "Backup: $backup" 'No save, restore, or Rex restart was run. Keep the backup and old binaries for manual recovery after interruption.'
