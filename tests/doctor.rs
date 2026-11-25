//! The doctor's macOS diagnostics, driven by a read-only `launchctl` stand-in.

#![cfg(target_os = "macos")]

mod common;

use std::fs;
use std::path::PathBuf;

use common::{NO_SERVER, RexurrectCmd, STATE_DIR_VAR, TestEnv, write_script};

const LABEL: &str = "io.github.cemcatik.rexurrect.doctor-test";

struct Launchctl<'a> {
    env: &'a TestEnv,
    bin: PathBuf,
    agents: PathBuf,
    calls: PathBuf,
    output: PathBuf,
}

impl<'a> Launchctl<'a> {
    fn new(env: &'a TestEnv) -> Self {
        let bin = env.mkdir("bin");
        write_script(
            &bin.join("launchctl"),
            r#"#!/bin/sh
printf '%s\n' "$*" >> "$DOCTOR_CALLS"
case "$*" in
  "print gui/"*"/$REXURRECT_AUTOSAVE_LABEL") ;;
  *) echo "unexpected launchctl call: $*" >&2; exit 64 ;;
esac
case "$DOCTOR_CASE" in
  loaded) cat "$DOCTOR_OUTPUT" ;;
  unloaded)
    echo "Could not find service \"$REXURRECT_AUTOSAVE_LABEL\" in domain for user gui" >&2
    exit 113 ;;
  query-error)
    echo "Could not find domain for user gui" >&2
    exit 125 ;;
esac
"#,
        );
        for name in ["rex", "rexurrect"] {
            write_script(
                &bin.join(name),
                "#!/bin/sh\nprintf 'unexpected program %s %s\\n' \"$0\" \"$*\" >> \"$DOCTOR_CALLS\"\nexit 64\n",
            );
        }
        Self {
            env,
            bin,
            agents: env.mkdir("LaunchAgents"),
            calls: env.root().join("calls"),
            output: env.root().join("launchctl-print"),
        }
    }

    fn doctor(&self, case: &str) -> RexurrectCmd {
        self.env
            .rexurrect_at(NO_SERVER)
            .path_prepend(&self.bin)
            .env("REXURRECT_SCHEDULER", "launchd")
            .env("REXURRECT_AUTOSAVE_LABEL", LABEL)
            .env("REXURRECT_LAUNCH_AGENTS_DIR", &self.agents)
            .env("DOCTOR_CALLS", &self.calls)
            .env("DOCTOR_OUTPUT", &self.output)
            .env("DOCTOR_CASE", case)
            .arg("doctor")
    }

    fn assert_only_print(&self) {
        let calls = fs::read_to_string(&self.calls).unwrap();
        let lines: Vec<_> = calls.lines().collect();
        assert_eq!(lines.len(), 1, "{calls}");
        assert!(lines[0].starts_with("print gui/"), "{calls}");
        assert!(lines[0].ends_with(LABEL), "{calls}");
    }
}

#[test]
fn doctor_checks_the_loaded_agents_pinned_state_without_writing() {
    let env = TestEnv::builder().own_home().build();
    let launchctl = Launchctl::new(&env);
    let pinned = env.mkdir("pinned state with spaces");
    let unpinned = env.root().join("caller-state");
    let snapshot = "snapshots/20261125T010203.000000Z.json";
    fs::create_dir(pinned.join("snapshots")).unwrap();
    fs::write(
        pinned.join(snapshot),
        r#"{"format":1,"taken_at":"2026-11-25T01:02:03.000000Z","sessions":[]}"#,
    )
    .unwrap();
    std::os::unix::fs::symlink(snapshot, pinned.join("latest.json")).unwrap();
    fs::write(
        &launchctl.output,
        format!(
            "gui/501/{LABEL} = {{\n\
             \tstate = not running\n\
             \tprogram = {}\n\
             \tdefault environment = {{\n\
             \t\tREXURRECT_STATE_DIR => /unexpected/default-state\n\
             \t}}\n\
             \tenvironment = {{\n\
             \t\tREX_SERVER => unix:///tmp/pinned.sock\n\
             \t\tREXURRECT_STATE_DIR => {}\n\
             \t\tREXURRECT_CONFIG => /tmp/pinned config.toml\n\
             \t}}\n\
             \truns = 7\n\
             \tlast exit code = 0\n\
             \tresource coalition = {{\n\
             \t\tstate = active\n\
             \t\tlast exit code = 77\n\
             \t}}\n\
             \trun interval = 900 seconds\n\
             \tproperties = inferred program\n\
             }}\n",
            launchctl.bin.join("rexurrect").display(),
            pinned.display(),
        ),
    )
    .unwrap();

    let out = launchctl
        .doctor("loaded")
        .env(STATE_DIR_VAR, &unpinned)
        .env("REXURRECT_KEEP", "9")
        .run()
        .assert_success();

    for expected in [
        "Last attempt",
        "Latest snapshot",
        "unix:///tmp/pinned.sock",
        pinned.to_str().unwrap(),
    ] {
        assert!(out.stdout.contains(expected), "missing {expected:?}: {out}");
    }
    assert!(
        out.stdout.contains("2026-11-25") || out.stdout.contains("20261125T010203"),
        "the loaded agent's snapshot was not reported: {out}"
    );
    assert!(!out.stdout.contains("unexpected/default-state"), "{out}");
    assert!(!unpinned.exists(), "check created caller state: {out}");
    assert_eq!(
        fs::read_dir(&pinned).unwrap().count(),
        2,
        "check wrote to the pinned state: {out}"
    );
    assert_eq!(
        fs::read_link(pinned.join("latest.json")).unwrap(),
        PathBuf::from(snapshot)
    );
    launchctl.assert_only_print();
}

#[test]
fn doctor_reports_launch_constraint_rejection_as_a_failed_attempt() {
    let env = TestEnv::builder().own_home().build();
    let launchctl = Launchctl::new(&env);
    fs::write(
        &launchctl.output,
        format!(
            "gui/501/{LABEL} = {{\n\
             \tstate = not running\n\
             \tprogram = {}\n\
             \truns = 1\n\
             \tlast exit reason = OS_REASON_CODESIGNING | Launch Constraint Violation, error info: c[5]p[1]m[1]e[0]\n\
             \tjob state = spawn failed\n\
             \tproperties = inferred program | needs LWCR update | managed LWCR | has LWCR\n\
             }}\n",
            launchctl.bin.join("rexurrect").display(),
        ),
    )
    .unwrap();

    let out = launchctl.doctor("loaded").run().assert_failure();

    let diagnostic = format!("{}{}", out.stdout, out.stderr);
    assert!(diagnostic.contains("Last attempt"), "{out}");
    assert!(diagnostic.contains("OS_REASON_CODESIGNING"), "{out}");
    assert!(diagnostic.contains("needs LWCR update"), "{out}");
    launchctl.assert_only_print();
}

#[test]
fn doctor_distinguishes_an_unloaded_agent_from_a_failed_scheduler_query() {
    let env = TestEnv::builder().own_home().build();
    let launchctl = Launchctl::new(&env);
    fs::write(
        launchctl.agents.join(format!("{LABEL}.plist")),
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\">\
             <dict><key>Label</key><string>{LABEL}</string></dict></plist>"
        ),
    )
    .unwrap();

    let out = launchctl.doctor("unloaded").run().assert_failure();
    assert!(
        format!("{}{}", out.stdout, out.stderr).contains("not loaded"),
        "{out}"
    );
    launchctl.assert_only_print();

    fs::remove_file(&launchctl.calls).unwrap();
    let out = launchctl.doctor("query-error").run().assert_failure();
    let diagnostic = format!("{}{}", out.stdout, out.stderr);
    assert!(
        diagnostic.contains("Could not find domain for user gui"),
        "{out}"
    );
    assert!(!diagnostic.contains("not loaded"), "{out}");
    launchctl.assert_only_print();
}
