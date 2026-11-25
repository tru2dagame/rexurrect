//! A forced autosave install reloads the existing LaunchAgent configuration.

#![cfg(target_os = "macos")]

mod common;

use std::fs;

use common::launchd::{FakeLaunchd, LABEL};
use common::{CONFIG_VAR, NO_SERVER, STATE_DIR_VAR, TestEnv};

#[test]
fn force_reloads_the_existing_plist_without_replacing_it_or_running_a_save() {
    let env = TestEnv::builder().own_home().build();
    let launchd = FakeLaunchd::new(&env);
    let state = env.mkdir("pinned state");
    launchd
        .aim(env.rexurrect_at(NO_SERVER))
        .env(STATE_DIR_VAR, &state)
        .args(["autosave", "install", "--interval", "7"])
        .run()
        .assert_success();
    assert_eq!(launchd.the_agent().start_interval(), 7 * 60);

    // The loaded agent retains its 7-minute interval. Make the installed
    // plist distinct so the test can tell whether the repair reloaded it.
    let plist = launchd.agents_dir().join(format!("{LABEL}.plist"));
    let edited = fs::read_to_string(&plist)
        .unwrap()
        .replace("<integer>420</integer>", "<integer>540</integer>");
    fs::write(&plist, &edited).unwrap();

    let caller_state = env.root().join("caller-state");
    let caller_config = env.root().join("caller-config.toml");
    fs::write(&caller_config, "this is invalid TOML").unwrap();
    launchd
        .aim(env.rexurrect_at("unix:///tmp/unrelated-rex.sock"))
        .env(STATE_DIR_VAR, &caller_state)
        .env(CONFIG_VAR, &caller_config)
        .args(["autosave", "install", "--force"])
        .run()
        .assert_success();

    assert_eq!(fs::read_to_string(&plist).unwrap(), edited);
    let agent = launchd.the_agent();
    assert_eq!(agent.start_interval(), 9 * 60);
    assert_eq!(
        agent.program_arguments(),
        [common::rexurrect::bin(), "save"]
    );
    assert!(agent.environment().contains(&("REX_SERVER", NO_SERVER)));
    assert!(
        agent
            .environment()
            .contains(&(STATE_DIR_VAR, state.to_str().unwrap()))
    );
    assert!(
        agent
            .environment()
            .contains(&(CONFIG_VAR, env.config_path().to_str().unwrap()))
    );
    assert!(!common::files::has_entries(&state));
    assert!(!caller_state.exists());

    let calls = fs::read_to_string(launchd.agents_dir().parent().unwrap().join("calls")).unwrap();
    assert!(
        calls.lines().any(|call| call.starts_with("bootout gui/")),
        "{calls}"
    );
    assert!(
        !calls.lines().any(|call| call.starts_with("kickstart")),
        "{calls}"
    );
}

#[test]
fn force_does_not_install_a_new_agent_or_accept_a_new_interval() {
    let env = TestEnv::builder().own_home().build();
    let launchd = FakeLaunchd::new(&env);
    launchd
        .aim(env.rexurrect_at(NO_SERVER))
        .args(["autosave", "install", "--force"])
        .run()
        .assert_failure();
    assert!(launchd.installed().is_empty());
    assert!(launchd.loaded().is_empty());

    launchd
        .aim(env.rexurrect_at(NO_SERVER))
        .args(["autosave", "install", "--interval", "7"])
        .run()
        .assert_success();
    for args in [
        &["autosave", "install", "--force", "--interval", "9"][..],
        &["setup", "--force"][..],
    ] {
        launchd
            .aim(env.rexurrect_at(NO_SERVER))
            .args(args)
            .run()
            .assert_failure();
    }
    assert_eq!(launchd.the_agent().start_interval(), 7 * 60);
}

#[test]
fn force_keeps_the_original_plist_when_launchd_refuses_to_reload() {
    let env = TestEnv::builder().own_home().build();
    let launchd = FakeLaunchd::new(&env);
    launchd
        .aim(env.rexurrect_at(NO_SERVER))
        .args(["autosave", "install", "--interval", "7"])
        .run()
        .assert_success();
    let path = launchd.agents_dir().join(format!("{LABEL}.plist"));
    let original = fs::read(&path).unwrap();
    launchd.refuse_to_load();

    let out = launchd
        .aim(env.rexurrect_at(NO_SERVER))
        .args(["autosave", "install", "--force"])
        .run()
        .assert_failure();

    assert!(out.stderr.contains("bootstrap"), "{out}");
    assert_eq!(fs::read(path).unwrap(), original);
    assert!(launchd.loaded().is_empty());
}
