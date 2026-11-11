use serde_json::{json, Value};
use std::path::PathBuf;
use termpilot_ai::{
    model::{Message, Protocol, Provider},
    provider::{Accumulator, Sse},
    store::Store,
};

#[test]
fn server_scope_survives_reconnect_without_admitting_another_host() {
    use termpilot_ai::tools::scope_contains;
    let before = json!({"hostId":"SERVER-A","sessionId":"old","scope":"tab-a"});
    let after = json!({"hostId":"SERVER-A","sessionId":"new","scope":"tab-a"});
    let other = json!({"hostId":"SERVER-B","sessionId":"other","scope":"tab-b"});
    assert!(scope_contains("host:server-a", &before));
    assert!(scope_contains("host:server-a", &after));
    assert!(!scope_contains("host:server-a", &other));
    assert!(!scope_contains("host:", &json!({"hostId":""})));
    assert!(scope_contains("tab-a", &before));
    assert!(!scope_contains("old", &after));
}

#[test]
fn installed_baseline_settings_defaults_and_legacy_records() {
    use termpilot_ai::{model::Settings, settings};
    let settings: Settings = serde_json::from_value(json!({"providers":[],"mode":"confirm","maxIterations":30,"search":{"kind":"tavily","apiKey":"existing-key"}})).unwrap();
    assert_eq!(settings.command_timeout, 60);
    assert_eq!(settings.max_iterations, 30); // Existing user choice is preserved.
    assert!(settings.selection_shortcut);
    assert!(!settings.tool_access.enabled);
    assert!(settings::search_enabled(&settings.search));
    let fresh = Settings::default();
    assert_eq!(fresh.max_iterations, 20);
    assert!(!settings::search_enabled(&fresh.search));
    settings::validate(&fresh).unwrap();
}

#[test]
fn javascript_command_rules_cover_split_flags_and_fail_closed() {
    use termpilot_ai::settings::{command_blocked, default_blacklist};
    let rules = default_blacklist();
    for command in [
        "rm -rf /tmp/fixture",
        "rm -r -f /tmp/fixture",
        "rm --force --recursive /tmp/fixture",
        "reboot",
        "printf $(id)",
    ] {
        assert!(command_blocked(&rules, Some(command)).unwrap(), "{command}");
    }
    assert!(!command_blocked(&rules, Some("printf 'safe'; ls -al /tmp")).unwrap());
    assert!(command_blocked(&["[".into()], None).is_err());
    assert!(!command_blocked(&[], Some("echo anything")).unwrap());
}

#[test]
fn settings_ranges_and_search_toggle_are_enforced() {
    use termpilot_ai::{model::Settings, settings};
    let mut s = Settings::default();
    s.command_timeout = 0;
    assert!(settings::validate(&s).is_err());
    s.command_timeout = 60;
    s.search = json!({"enabled":false,"kind":"tavily","apiKey":"configured-key","maxResults":21});
    assert!(!settings::search_enabled(&s.search));
    assert!(settings::validate(&s).is_err());
    s.search["maxResults"] = json!(5);
    settings::validate(&s).unwrap();
    s.tool_access.idle_minutes = 0;
    assert!(settings::validate(&s).is_err());
}

#[test]
fn native_numeric_parameters_translate_to_vendor_wire_names() {
    use termpilot_ai::provider::body;
    for (protocol, key) in [
        (Protocol::Chat, "max_tokens"),
        (Protocol::Responses, "max_output_tokens"),
        (Protocol::Anthropic, "max_tokens"),
    ] {
        let p = Provider {
            protocol,
            model: "fixture".into(),
            parameters: json!({"max_tokens":1234}),
            ..Default::default()
        };
        assert_eq!(body(&p, &[], &[]).unwrap().1[key], 1234);
    }
    let p = Provider {
        protocol: Protocol::Google,
        model: "fixture".into(),
        parameters: json!({"max_tokens":1234,"temperature":0.7,"top_p":0.9}),
        ..Default::default()
    };
    let b = body(&p, &[], &[]).unwrap().1;
    assert_eq!(b["generationConfig"]["maxOutputTokens"], 1234);
    assert_eq!(b["generationConfig"]["topP"], 0.9);
}

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("TermPilot-ai-test-{}", uuid::Uuid::new_v4())))
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn encrypted_records_survive_restart_without_plaintext() {
    let d = Directory::new();
    let marker = "secret-ai-key-中文";
    {
        let store = Store::open(&d.0).unwrap();
        store
            .put("settings", "main", &json!({"apiKey":marker}))
            .unwrap();
        store.put("drafts", "a", &json!({"text":marker})).unwrap();
    }
    for path in std::fs::read_dir(&d.0).unwrap() {
        let bytes = std::fs::read(path.unwrap().path()).unwrap();
        assert!(!bytes.windows(marker.len()).any(|s| s == marker.as_bytes()));
    }
    let store = Store::open(&d.0).unwrap();
    assert_eq!(
        store.get::<Value>("settings", "main").unwrap().unwrap()["apiKey"],
        marker
    );
    assert_eq!(store.list::<Value>("drafts").unwrap().len(), 1);
    store.delete("drafts", "a").unwrap();
    assert!(store.list::<Value>("drafts").unwrap().is_empty());
}
#[test]
fn existing_vault_key_is_required_and_never_recreated() {
    let d = Directory::new();
    std::fs::create_dir_all(&d.0).unwrap();
    std::fs::write(d.0.join("vault.sqlite"), b"existing").unwrap();
    assert!(Store::open(&d.0).is_err());
    assert!(!d.0.join("credential.key").exists());
}
#[test]
fn existing_key_bytes_are_preserved() {
    let d = Directory::new();
    std::fs::create_dir_all(&d.0).unwrap();
    let key = vec![7u8; 32];
    std::fs::write(d.0.join("credential.key"), &key).unwrap();
    let store = Store::open(&d.0).unwrap();
    store.put("settings", "main", &json!({})).unwrap();
    assert_eq!(std::fs::read(d.0.join("credential.key")).unwrap(), key);
}
#[test]
fn authenticated_encryption_binds_record_identity() {
    let d = Directory::new();
    {
        let store = Store::open(&d.0).unwrap();
        store.put("drafts", "a", &json!({"x":1})).unwrap();
    }
    let db = rusqlite::Connection::open(d.0.join("ai.sqlite")).unwrap();
    // Simulate storage tampering outside the application. This connection has
    // no journal encryption function, so bypass triggers for the forged write.
    db.set_db_config(
        rusqlite::config::DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER,
        false,
    )
    .unwrap();
    db.execute("UPDATE records SET id='b'", []).unwrap();
    let store = Store::open(&d.0).unwrap();
    assert!(store.get::<Value>("drafts", "b").is_err());
}
#[test]
fn split_sse_is_utf8_safe_and_supports_crlf_multiline() {
    let wire = "event: message\r\ndata: {\"text\":\"中文😀\",\r\ndata: \"done\":true}\r\n\r\n";
    for split in 0..wire.len() {
        let mut s = Sse::default();
        let mut events = s.push(&wire.as_bytes()[..split]).unwrap();
        events.extend(s.push(&wire.as_bytes()[split..]).unwrap());
        assert_eq!(events.len(), 1);
        assert_eq!(
            serde_json::from_str::<Value>(&events[0]).unwrap()["text"],
            "中文😀"
        );
    }
}
#[test]
fn sse_line_is_bounded() {
    let mut s = Sse::default();
    assert!(s.push(&vec![b'a'; 8 * 1024 * 1024 + 1]).is_err());
}
#[test]
fn chat_interleaved_tool_fragments_assemble_by_index() {
    let mut a = Accumulator::default();
    a.accept(&Protocol::Chat,&json!({"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"sftp_list","arguments":"{\"path\":"}},{"index":0,"id":"a","function":{"name":"get_environment","arguments":"{"}}]}}]})).unwrap();
    a.accept(&Protocol::Chat,&json!({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}},{"index":1,"function":{"arguments":"\"/tmp\"}"}}]},"finish_reason":"tool_calls"}]})).unwrap();
    let (m, _) = a.finish(&Protocol::Chat).unwrap();
    assert_eq!(m.calls[0].id, "a");
    assert_eq!(m.calls[1].arguments["path"], "/tmp");
}
#[test]
fn incomplete_chat_is_not_success() {
    let a = Accumulator::default();
    assert!(a.finish(&Protocol::Chat).is_err());
    let mut a = Accumulator::default();
    assert!(a
        .accept(
            &Protocol::Chat,
            &json!({"choices":[{"delta":{},"finish_reason":"length"}]})
        )
        .is_err());
}
#[test]
fn responses_preserve_reasoning_and_function_call_ids() {
    let mut a = Accumulator::default();
    a.accept(&Protocol::Responses,&json!({"type":"response.completed","response":{"output":[{"type":"reasoning","id":"r","summary":[]},{"type":"function_call","call_id":"call1","name":"get_environment","arguments":"{}"}],"usage":{"input_tokens":12}}})).unwrap();
    let (m, u) = a.finish(&Protocol::Responses).unwrap();
    assert_eq!(m.calls[0].id, "call1");
    assert_eq!(u["input_tokens"], 12);
    let p = Provider {
        protocol: Protocol::Responses,
        model: "test".into(),
        ..Default::default()
    };
    let (_, b) = termpilot_ai::provider::body(
        &p,
        &[
            m,
            Message {
                role: "tool".into(),
                call_id: "call1".into(),
                content: "{}".into(),
                ..Default::default()
            },
        ],
        &[],
    )
    .unwrap();
    assert_eq!(b["input"][0]["type"], "reasoning");
    assert_eq!(b["input"][2]["call_id"], "call1");
}
#[test]
fn anthropic_keeps_signed_thinking_and_tool_json() {
    let mut a = Accumulator::default();
    for v in [
        json!({"type":"message_start","message":{"usage":{"input_tokens":8}}}),
        json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"summary"}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}),
        json!({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c1","name":"sftp_list","input":{}}}),
        json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/tmp\"}"}}),
        json!({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}),
        json!({"type":"message_stop"}),
    ] {
        a.accept(&Protocol::Anthropic, &v).unwrap();
    }
    let (m, u) = a.finish(&Protocol::Anthropic).unwrap();
    assert_eq!(m.provider_data[0]["signature"], "signed");
    assert_eq!(m.provider_data[1]["input"]["path"], "/tmp");
    assert_eq!(u["input_tokens"], 8);
    assert_eq!(u["output_tokens"], 20);
}
#[test]
fn google_preserves_thought_signatures() {
    let mut a = Accumulator::default();
    a.accept(&Protocol::Google,&json!({"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_environment","args":{}},"thoughtSignature":"signed"}]},"finishReason":"STOP"}]})).unwrap();
    let (m, _) = a.finish(&Protocol::Google).unwrap();
    assert_eq!(m.provider_data[0]["thoughtSignature"], "signed");
    assert_eq!(m.calls.len(), 1);
}
#[test]
fn unsupported_provider_parameters_fail_explicitly() {
    let p = Provider {
        model: "test".into(),
        parameters: json!({"bogus":true}),
        ..Default::default()
    };
    assert!(termpilot_ai::provider::body(&p, &[], &[]).is_err());
}
#[test]
fn provider_urls_cannot_embed_credentials() {
    let p = Provider {
        base_url: "https://user:secret@example.com/v1".into(),
        ..Default::default()
    };
    assert!(termpilot_ai::provider::client(&p).is_err());
}
#[test]
fn secret_projection_strips_nested_credentials() {
    let v = termpilot_ai::tools::redact(
        json!({"id":"host","password":"secret","proxy":{"password":"p"},"identityKey":"key"}),
    );
    assert_eq!(v["id"], "host");
    assert!(v["password"].is_null());
    assert!(v["proxy"]["password"].is_null());
    assert!(v["identityKey"].is_null());
}
#[test]
fn all_baseline_tools_have_unique_schemas() {
    let specs = termpilot_ai::tools::catalog();
    assert_eq!(specs.len(), 74);
    let names: std::collections::HashSet<_> =
        specs.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(names.len(), 74);
    for s in specs {
        assert_eq!(s["inputSchema"]["type"], "object");
    }
}
#[cfg(unix)]
#[test]
fn skills_cannot_escape_the_user_skill_directory() {
    use std::os::unix::fs::symlink;
    let d = Directory::new();
    let outside = Directory::new();
    std::fs::create_dir_all(d.0.join("skills/evil")).unwrap();
    std::fs::create_dir_all(&outside.0).unwrap();
    std::fs::write(outside.0.join("SKILL.md"), "private").unwrap();
    symlink(outside.0.join("SKILL.md"), d.0.join("skills/evil/SKILL.md")).unwrap();
    assert!(termpilot_ai::tools::skills(&d.0)
        .unwrap()
        .as_array()
        .unwrap()
        .is_empty());
}
#[test]
fn external_scripts_are_rejected_without_execution() {
    let d = Directory::new();
    std::fs::create_dir_all(&d.0).unwrap();
    let script = d.0.join("codex");
    std::fs::write(&script, b"#!/usr/bin/env node\n").unwrap();
    assert!(termpilot_ai::external::native_executable(script.to_str().unwrap()).is_err());
}

#[test]
fn host_preview_has_no_side_effects_and_duplicates_are_skipped() {
    let dir = Directory::new();
    let input = json!({"hosts":json!([{"hostname":"localhost","username":"fixture","label":"Fixture","group":"new/nested"}]).to_string(),"dryRun":"true"});
    let preview = termpilot_ai::domain::execute(&dir.0, "vault_hosts_create", &input).unwrap();
    assert_eq!(preview["created"], 0);
    let vault = termpilot_core::vault::Vault::open(&dir.0, None).unwrap();
    assert!(vault.list("hosts").unwrap().is_empty());
    assert!(vault.list("groups").unwrap().is_empty());
    let mut actual = input;
    actual["dryRun"] = json!("false");
    assert_eq!(
        termpilot_ai::domain::execute(&dir.0, "vault_hosts_create", &actual).unwrap()["created"],
        1
    );
    assert_eq!(
        termpilot_ai::domain::execute(&dir.0, "vault_hosts_create", &actual).unwrap()["skipped"],
        1
    );
}

#[test]
fn forward_string_flags_are_normalized_and_unsupported_reconnect_is_rejected() {
    let dir = Directory::new();
    let a = json!({"type":"dynamic","localPort":1080,"autoStart":"false"});
    let rule = termpilot_ai::domain::execute(&dir.0, "portforward_rules_create", &a).unwrap();
    assert_eq!(rule["autoStart"], false);
    let mut bad = a;
    bad["autoReconnect"] = json!("true");
    assert!(termpilot_ai::domain::execute(&dir.0, "portforward_rules_create", &bad).is_err());
}

#[test]
fn native_script_forms_validate_visibility_numbers_and_protected_keys() {
    use termpilot_ai::forms::{normalize, validate};
    let spec=normalize("dialog.form",&json!([{"fields":[{"name":"advanced","type":"checkbox"},{"name":"port","type":"number","min":1,"max":65535,"step":1,"visibleWhen":{"field":"advanced","truthy":true}}]}])).unwrap();
    assert_eq!(
        validate(&spec, &json!({"advanced":false,"port":"invalid"})).unwrap(),
        json!({"advanced":false})
    );
    assert_eq!(
        validate(&spec, &json!({"advanced":true,"port":"22"})).unwrap()["port"],
        22.0
    );
    assert!(validate(&spec, &json!({"advanced":true,"port":"22.5"})).is_err());
    assert!(normalize("dialog.form", &json!([{"fields":[{"name":"__proto__"}]}])).is_err());
    assert!(normalize(
        "dialog.form",
        &json!([{"fields":[{"name":"x","visibleWhen":{"field":"later","truthy":true}}]}])
    )
    .is_err());
}

#[test]
fn malformed_dialog_values_are_errors_and_do_not_panic() {
    let spec = termpilot_ai::forms::normalize("dialog.prompt", &json!(["Question", ""])).unwrap();
    for value in [Value::Null, json!([]), json!("text")] {
        assert!(termpilot_ai::forms::validate(&spec, &value).is_err());
    }
}

#[test]
fn encrypted_batch_rolls_back_all_records_on_error() {
    let dir = Directory::new();
    let store = Store::open(&dir.0).unwrap();
    store.put("batch", "first", &json!({"old":true})).unwrap();
    let too_large = json!("x".repeat(32 * 1024 * 1024));
    assert!(store
        .put_batch(&[
            ("batch", "first".into(), json!({"new":true})),
            ("batch", "second".into(), too_large)
        ])
        .is_err());
    assert_eq!(
        store.get::<Value>("batch", "first").unwrap().unwrap(),
        json!({"old":true})
    );
    assert!(store.get::<Value>("batch", "second").unwrap().is_none());
}

#[test]
fn model_catalog_normalizes_provider_formats_without_rewriting_custom_ids() {
    use termpilot_ai::provider::model_ids;
    assert_eq!(
        model_ids(
            &json!({"data":[{"id":"model-b"},{"id":"model-a"},{"id":"model-b"},{"id":" "}]}),
            &Protocol::Chat
        )
        .unwrap(),
        vec!["model-a", "model-b"]
    );
    assert_eq!(
        model_ids(
            &json!({"models":[{"name":"models/gemini-test"}]}),
            &Protocol::Google
        )
        .unwrap(),
        vec!["gemini-test"]
    );
    assert_eq!(
        model_ids(
            &json!({"data":[{"id":"models/custom"}]}),
            &Protocol::Responses
        )
        .unwrap(),
        vec!["models/custom"]
    );
    assert_eq!(
        model_ids(&json!(["one", {"model":"two"}]), &Protocol::Chat).unwrap(),
        vec!["one", "two"]
    );
    assert!(model_ids(&json!({"data":[]}), &Protocol::Anthropic)
        .unwrap()
        .is_empty());
    assert!(model_ids(&json!({"error":"bad credentials"}), &Protocol::Chat).is_err());
    assert!(model_ids(
        &json!({"data":[{"display_name":"not an ID"}]}),
        &Protocol::Chat
    )
    .is_err());
}
