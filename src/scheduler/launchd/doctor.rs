//! Read the current GUI job's status and its latest snapshot pointer.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::ExitCode;

use super::Launchd;
use crate::config::CONFIG_VAR;
use crate::error::Result;
use crate::rex::SERVER_VAR;
use crate::state::{STATE_DIR_VAR, StateDir};
use crate::store::SnapshotStore;
use crate::timestamp::Timestamp;

pub(super) fn check(agent: &Launchd) -> Result<ExitCode> {
    println!("Autosave: {}", agent.service());
    let Some(text) = agent.print_status()? else {
        let path = agent.plist_path();
        if path.is_file() {
            println!("LaunchAgent: not loaded ({})", path.display());
            println!("Reload it with `rexurrect autosave install --force`.");
        } else {
            println!("LaunchAgent: not loaded, no plist at {}", path.display());
            println!("Set it up with `rexurrect autosave install`.");
        }
        return Ok(ExitCode::FAILURE);
    };

    println!("LaunchAgent: loaded");
    if let Some(path) = field(&text, "path") {
        println!("Plist: {path}");
    }
    let interval = field(&text, "run interval");
    println!("Interval: {}", interval.unwrap_or("unknown"));
    if let Some(runs) = field(&text, "runs") {
        println!("Runs: {runs}");
    }
    if let Some(server) = pinned(&text, SERVER_VAR) {
        println!("Rex server: {server}");
    }
    if let Some(config) = pinned(&text, CONFIG_VAR) {
        println!("Config: {config}");
    }
    let program_ok = check_program(&text);
    let attempt_ok = check_attempt(&text);
    let snapshot_ok = check_snapshot(&text)?;
    if interval.is_some() && program_ok && attempt_ok && snapshot_ok {
        Ok(ExitCode::SUCCESS)
    } else {
        Ok(ExitCode::FAILURE)
    }
}

fn check_program(text: &str) -> bool {
    let Some(program) = field(text, "program") else {
        println!("Program: unknown");
        return false;
    };
    let path = Path::new(program);
    let executable = path.is_absolute()
        && fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0);
    if executable {
        println!("Program: {program}");
    } else {
        println!("Program: {program} (missing or not executable)");
    }
    executable
}

fn check_attempt(text: &str) -> bool {
    let reason = field(text, "last exit reason");
    let spawn_failed = field(text, "job state") == Some("spawn failed");
    let code = if field(text, "runs") == Some("0") {
        None
    } else {
        field(text, "last exit code").and_then(|value| value.parse::<i32>().ok())
    };
    let constraint_pending = field(text, "properties")
        .is_some_and(|value| value.split(" | ").any(|flag| flag == "needs LWCR update"));
    if let Some(reason) = reason {
        println!("Last attempt: {reason}");
    } else if spawn_failed {
        println!("Last attempt: spawn failed");
    } else if let Some(code) = code {
        println!("Last attempt: exit {code}");
    } else {
        println!("Last attempt: no completed result available");
    }
    if constraint_pending {
        println!("Launch constraint: needs LWCR update");
    }
    if constraint_pending || reason.is_some_and(|value| value.contains("OS_REASON_CODESIGNING")) {
        println!("If this followed an upgrade, reload with `rexurrect autosave install --force`.");
    }
    reason.is_none() && !spawn_failed && code == Some(0) && !constraint_pending
}

fn check_snapshot(text: &str) -> Result<bool> {
    let Some(path) = pinned(text, STATE_DIR_VAR)
        .map(Path::new)
        .filter(|path| path.is_absolute())
    else {
        println!("Latest snapshot: unknown (no absolute {STATE_DIR_VAR} in the loaded job)");
        return Ok(false);
    };
    println!("State directory: {}", path.display());
    let state = StateDir::at(path.to_path_buf());
    let store = SnapshotStore::new(&state);
    match store.latest_update()? {
        Some((target, updated)) => {
            print!(
                "Latest snapshot: {} (latest.json updated {})",
                target.display(),
                updated.display()
            );
            if let Some(age) = Timestamp::now().since(updated) {
                print!(", {} minutes ago", age.as_secs() / 60);
            }
            println!();
        }
        None => println!("Latest snapshot: no latest.json yet"),
    }
    Ok(true)
}

// launchctl print is for humans. Only read the known fields at their expected
// nesting level and report unknown values instead of guessing.
fn top_level(line: &str) -> Option<&str> {
    line.strip_prefix('\t')
        .filter(|line| !line.starts_with('\t'))
}

fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines().filter_map(top_level).find_map(|line| {
        let (name, value) = line.split_once(" = ")?;
        (name == key && !value.is_empty()).then_some(value)
    })
}

fn pinned<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines()
        .skip_while(|line| top_level(line) != Some("environment = {"))
        .skip(1)
        .take_while(|line| top_level(line) != Some("}"))
        .find_map(|line| {
            let (name, value) = line.strip_prefix("\t\t")?.split_once(" => ")?;
            (name == key && !value.is_empty()).then_some(value)
        })
}
