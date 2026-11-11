//! A command block kept open after its process exits still has scrollback
//! and a place in its window's layout, but no program to resume.

mod common;

use std::path::Path;

use common::server::{above_prompt, wait_for};
use common::*;
use serde_json::{Value, json};

/// Use the real CLI's keep-open option: the exited state must come from Rex,
/// not a stub that merely removes `foreground` from a running terminal.
fn exited_command(
    server: &Server,
    session: &str,
    anchor: &str,
    direction: &str,
    cwd: &Path,
    label: &str,
    command: &str,
) -> (String, Value) {
    let out = server
        .rex()
        .args([
            "run",
            "--session",
            session,
            "--block",
            anchor,
            "--split",
            direction,
            "--ratio",
            "50",
            "--cwd",
            cwd.to_str().unwrap(),
            "--label",
            label,
            "--keep-open",
            "--focus=false",
            "--shell=none",
            "--json",
            "--",
            "/bin/sh",
            "-c",
            command,
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "rex run failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let created: Value = serde_json::from_slice(&out.stdout).unwrap();
    let block = created["block_ids"][0]
        .as_str()
        .unwrap_or_else(|| panic!("rex run did not return a block ID: {created}"))
        .to_string();
    let process = wait_for("the kept-open command's exit", || {
        let process = server.block_method(session, &block, "process", json!({}));
        process["last_exit"]["exit_code"].as_i64().map(|_| process)
    });
    assert!(process.get("foreground").is_none_or(Value::is_null));
    assert!(process.get("child").is_none_or(Value::is_null));
    (block, process)
}

#[test]
fn exited_commands_keep_their_scrollback_layout_labels_and_directories_without_running_again() {
    let env = TestEnv::builder().own_home().build();
    let server = env.start_server();
    let [live_dir, reported_dir, quiet_dir] =
        ["live", "reported", "quiet"].map(|name| env.mkdir(name));
    let fixture = server.create_session(
        "zz-exited-commands",
        &[window(shell(&live_dir).labeled("live shell")).labeled("kept output")],
    );
    let live = fixture.block_ids()[0];
    server.wait_for_pwd(&fixture.id, live);
    server.run(&fixture.id, live, "echo zz-live-sibling");
    server.wait_for_capture(&fixture.id, live, "the live shell's output", |c| {
        c.contains("\nzz-live-sibling")
    });

    let marker = env.root().join("command-runs");
    let reported_command = format!(
        "printf 'reported\\n' >> '{}'; printf '\\033]7;file://localhost{}\\007'; \
         printf 'zz-exited-zero\\n'; exit 0",
        marker.display(),
        reported_dir.display(),
    );
    let (reported, reported_process) = exited_command(
        &server,
        &fixture.id,
        live,
        "right",
        &reported_dir,
        "finished successfully",
        &reported_command,
    );
    assert_eq!(reported_process["last_exit"]["exit_code"], 0);
    let quiet_command = format!(
        "printf 'quiet\\n' >> '{}'; printf 'zz-exited-nine\\n'; exit 9",
        marker.display(),
    );
    let (quiet, quiet_process) = exited_command(
        &server,
        &fixture.id,
        &reported,
        "below",
        &quiet_dir,
        "finished with error",
        &quiet_command,
    );
    assert_eq!(quiet_process["last_exit"]["exit_code"], 9);
    assert_eq!(
        server.pwd(&fixture.id, &reported).as_deref(),
        Some(reported_dir.to_str().unwrap()),
    );
    assert_eq!(server.pwd(&fixture.id, &quiet), None);
    for (block, output) in [(&reported, "zz-exited-zero"), (&quiet, "zz-exited-nine")] {
        server.wait_for_capture(&fixture.id, block, output, |c| c.contains(output));
    }
    assert_eq!(
        std::fs::read_to_string(&marker).unwrap(),
        "reported\nquiet\n"
    );

    env.save(&server);
    // A different isolated server exercises the same boundary as a restart.
    drop(server);
    std::fs::remove_file(&marker).unwrap();
    let restored_server = env.start_server();
    env.restore(&restored_server);
    let restored = restored_server.the_session_labelled("zz-exited-commands");
    let blocks = restored_server.block_ids(&restored);
    assert_eq!(blocks.len(), 3);
    for block in &blocks {
        restored_server.wait_for_empty_prompt(&restored, block);
    }
    assert_eq!(
        restored_server.window_shapes(&restored),
        vec![
            hsplit(
                0.5,
                shell(&live_dir),
                vsplit(0.5, shell(&reported_dir), shell(env.home())),
            )
            .expected_shape()
        ],
        "an exited block keeps its reported directory or falls back to home",
    );
    let restored_labels = labels(&restored_server.view(&restored));
    assert_eq!(restored_labels[0].label, "kept output");
    assert_eq!(
        restored_labels[0].block_labels,
        ["live shell", "finished successfully", "finished with error"],
    );
    for (block, output) in
        blocks
            .iter()
            .zip(["zz-live-sibling", "zz-exited-zero", "zz-exited-nine"])
    {
        let capture = restored_server.capture(&restored, block);
        assert!(above_prompt(&capture).contains(&output), "{capture}");
    }
    assert!(
        !marker.exists(),
        "restoring must not run exited commands again"
    );
}
