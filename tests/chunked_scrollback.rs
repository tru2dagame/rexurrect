//! Scrollback larger than one Rex response survives a save and a server
//! restart. The assertions read the restored terminal, not snapshot files.

mod common;

use common::server::{WAIT, wait_for_file, wait_for_or_none};
use common::zsh::quote;
use common::*;
use serde_json::json;

const CHUNK_BYTES: usize = 128 * 1024;
const ROWS: usize = 18_000;
const FIRST: &str = "zz-first-scrollback-最早🙂";
const LAST: &str = "zz-last-scrollback-最新🙂";

/// The regular capture helper deliberately uses Rex's CLI. Read through
/// the terminal methods here so verification itself does not depend on a
/// CLI build's ability to print more than one response's worth of output.
fn capture(server: &Server, session: &str, block: &str, format: &str) -> String {
    let first = server.block_method(
        session,
        block,
        "format",
        json!({
            "format": format,
            "trim": true,
            "unwrap": true,
            "max_bytes": CHUNK_BYTES,
        }),
    );
    let mut content = first["content"]
        .as_str()
        .expect("format content")
        .to_string();
    if let Some(id) = first.get("id").filter(|id| !id.is_null()) {
        loop {
            let next = server.block_method(
                session,
                block,
                "blob_read",
                json!({ "id": id, "offset": content.len(), "max_bytes": CHUNK_BYTES }),
            );
            let data = next["data"].as_str().expect("blob data");
            let eof = next["eof"].as_bool().expect("blob eof");
            assert!(eof || !data.is_empty(), "blob made no progress: {next}");
            content.push_str(data);
            if eof {
                break;
            }
        }
    }
    if let Some(total) = first.get("total").and_then(|total| total.as_u64()) {
        assert_eq!(content.len() as u64, total, "complete terminal format blob");
    }
    content
}

fn row(index: usize) -> String {
    format!("zz-large-{index:05} 中文🙂 色彩 abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmno")
}

fn wait_for_prompt(server: &Server, session: &str, block: &str, typed: &str) -> String {
    let mut last = String::new();
    wait_for_or_none(WAIT, || {
        let text = capture(server, session, block, "text");
        if text.contains(LAST) && text.trim_end().ends_with(typed) {
            Some(text)
        } else {
            last = text;
            None
        }
    })
    .unwrap_or_else(|| {
        let tail: String = last
            .chars()
            .rev()
            .take(300)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        panic!(
            "block {block} did not show complete scrollback and prompt suffix {typed:?}; \
             bytes={}, lines={}, first={}, last={}, tail={tail:?}",
            last.len(),
            last.lines().count(),
            last.contains(FIRST),
            last.contains(LAST),
        )
    })
}

#[test]
fn colored_unicode_scrollback_over_one_mib_survives_a_server_restart_in_full() {
    let env = TestEnv::with_recorder();
    let dir = env.mkdir("large-output");
    let output_file = dir.join("output.vt");
    let marker = dir.join("last-command-ran");
    let mut output = format!("{FIRST}\n");
    for index in 0..ROWS {
        output.push_str(&format!("\x1b[31m{}\x1b[0m\n", row(index)));
    }
    output.push_str(&format!("{LAST}\n"));
    std::fs::write(&output_file, output).unwrap();

    let server = env.start_server();
    let fixture = server.create_session("zz-chunked", &[window(shell(&dir))]);
    server.wait_for_pwds(&fixture);
    let block = fixture.block_ids()[0];
    server.resize(&fixture.id, block, 120, 24);
    server.run(&fixture.id, block, &format!("cat {}", quote(&output_file)));
    let before = wait_for_prompt(&server, &fixture.id, block, " %");
    assert!(before.len() > 1024 * 1024, "fixture must exceed one MiB");
    assert!(before.contains(FIRST), "oldest output is still in Rex");

    // The last command has a visible side effect. Restore must type it,
    // never run it, even after replaying a multi-response scrollback.
    let touch = format!("touch {}", quote(&marker));
    server.run(&fixture.id, block, &touch);
    wait_for_file(&marker);
    wait_for_prompt(&server, &fixture.id, block, " %");
    env.save(&server);

    let old_session = fixture.id.clone();
    drop(server); // Stops only this test's private server and its programs.
    std::fs::remove_file(&marker).unwrap();
    let restarted = env.start_server();
    env.restore(&restarted);

    let restored = restarted.the_session_labelled("zz-chunked");
    assert_ne!(restored, old_session, "restored on the new server instance");
    let block = restarted.block_ids(&restored).remove(0);
    let after = wait_for_prompt(&restarted, &restored, &block, &touch);
    restarted.wait_for_pwd_eq(&restored, &block, &dir);
    assert!(!marker.exists(), "the typed last command must not run");
    assert!(after.len() > 1024 * 1024, "restored output exceeds one MiB");
    assert!(after.contains(FIRST), "oldest sentinel was restored");
    assert!(after.contains(LAST), "newest sentinel was restored");

    // Check every distinct line, in order, so a missing middle chunk or
    // a UTF-8 byte/character offset error cannot pass on sentinels alone.
    let lines: Vec<&str> = after
        .lines()
        .map(|line| line.trim_end_matches('\r'))
        .collect();
    let first_row = lines
        .iter()
        .position(|line| *line == row(0))
        .expect("first row");
    for index in 0..ROWS {
        assert_eq!(
            lines.get(first_row + index).copied(),
            Some(row(index).as_str()),
            "restored line {index}"
        );
    }

    let vt = capture(&restarted, &restored, &block, "vt");
    let first_row_offset = vt.find("zz-large-00000").expect("first colored VT row");
    let style_prefix = vt[..first_row_offset].rsplit('\n').next().unwrap();
    assert!(
        style_prefix.contains("\x1b[31m")
            || style_prefix.contains("\x1b[0;31m")
            || style_prefix.contains("\x1b[38;5;1m"),
        "the replay retains the red SGR style; first row prefix={style_prefix:?}"
    );
    assert!(vt.contains("中文🙂 色彩"), "colored Unicode is retained");
    assert!(
        env.log_entries()
            .iter()
            .all(|entry| !entry.contains("fell back")),
        "large scrollback must not silently fall back: {:?}",
        env.log_entries()
    );
}

#[test]
fn stalled_or_malformed_blob_reads_fail_save_and_preserve_the_latest_snapshot() {
    let env = TestEnv::new();
    let server = env.start_server();
    let fixture = server.create_session("zz-blob-failure", &[window(shell(env.mkdir("a")))]);
    server.wait_for_pwds(&fixture);
    let block = fixture.block_ids()[0];
    server.run(&fixture.id, block, "echo zz-saved-before-blob-error");
    server.wait_for_capture(&fixture.id, block, "saved output", |text| {
        text.contains("\nzz-saved-before-blob-error\n") && text.trim_end().ends_with(" %")
    });
    env.save(&server);
    let listed_before = env.listed(&server);

    server.run(&fixture.id, block, "echo zz-unsaved-after-blob-error");
    server.wait_for_empty_prompt(&fixture.id, block);
    let partial = || {
        RexStub::new(&env).answer_when(
            "block.method",
            r#""unwrap":true"#,
            &json!({ "content": "zz-first-part", "id": 17, "total": 100 }),
        )
    };
    let mut stubs = Vec::new();
    for answer in [
        json!({ "id": 17, "data": "", "total": 100, "eof": false }),
        json!({ "id": 17, "data": "zz-partial", "total": 100 }),
    ] {
        stubs.push(partial().answer_when("block.method", r#""method":"blob_read""#, &answer));
    }
    for failure in [
        "Error: blob expired (status=404 code=not_found)",
        "Error: control response exceeds 1048576 bytes (status=413 code=too_large)",
    ] {
        stubs.push(partial().fail_when("block.method", r#""method":"blob_read""#, 1, failure));
    }
    for stub in stubs {
        let failed = env
            .rexurrect(&server)
            .path_prepend(stub.dir())
            .arg("save")
            .run()
            .assert_failure();
        assert!(
            failed.stderr.contains("zz-blob-failure"),
            "failure names its session: {failed}"
        );
        assert!(
            failed.stderr.contains("blob"),
            "failure names its blob read: {failed}"
        );
        assert_eq!(
            env.listed(&server),
            listed_before,
            "failed save publishes nothing"
        );
    }

    server.kill_session(&fixture.id);
    env.restore(&server);
    let restored = server.the_session_labelled("zz-blob-failure");
    let block = server.block_ids(&restored).remove(0);
    let text = server.wait_for_capture(&restored, &block, "the last good snapshot", |text| {
        text.contains("\nzz-saved-before-blob-error\n") && text.trim_end().ends_with(" %")
    });
    assert!(!text.contains("zz-unsaved-after-blob-error"));
    assert!(!text.contains("zz-first-part"));
}
