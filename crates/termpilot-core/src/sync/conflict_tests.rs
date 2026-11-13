use super::{
    lease_tests::Fixture,
    model::{Action, Vector},
    store::Store,
    *,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
fn append(store: &Store<'_>, scope: &str, writer: &str, id: &str, fields: Value) {
    store
        .append(
            scope,
            writer,
            &Vector::new(),
            "hosts",
            id,
            Action::Patch {
                fields: serde_json::from_value(fields).unwrap(),
            },
        )
        .unwrap();
}
fn describe(store: &Store<'_>, scope: &str, id: &str) -> Value {
    let state = store.state(scope).unwrap();
    conflicts::describe(
        store,
        &store.config().unwrap(),
        scope,
        id,
        &state.records[id],
        &state,
    )
    .unwrap()
}
#[test]
fn host_conflicts_have_identity_address_labels_and_distinct_field_values() {
    let f = Fixture::new();
    let v = f.peer("My Mac");
    let s = Store::new(&v).unwrap();
    append(
        &s,
        "configuration",
        "a",
        "host",
        json!({"label":"Development server","hostname":"dev.invalid","sort_order":1,"port":22}),
    );
    append(
        &s,
        "configuration",
        "b",
        "host",
        json!({"label":"Development server","hostname":"dev.invalid","sort_order":2,"port":22}),
    );
    let result = describe(&s, "configuration", "hosts/host");
    assert_eq!(result["title"], "主机：Development server");
    assert_eq!(result["subtitle"], "dev.invalid:22");
    let details = result["details"].as_array().unwrap();
    assert_eq!(details.len(), 1);
    assert_eq!(details[0]["label"], "排列顺序");
    assert!(details[0]["hint"]
        .as_str()
        .unwrap()
        .contains("不是主机地址"));
    assert_eq!(details[0]["candidates"][0]["source"]["name"], "My Mac");
    assert_eq!(details[0]["candidates"][0]["source"]["local"], true);
}
#[test]
fn credentials_stay_masked_until_explicit_candidate_reveal_and_stale_resolution_is_rejected() {
    let f = Fixture::new();
    let v = f.peer("Fixture Mac");
    let s = Store::new(&v).unwrap();
    let mut c = s.config().unwrap();
    c.scopes.push("credentials".into());
    c.scope_keys.insert("credentials".into(), vec![8; 32]);
    s.put("config", &c).unwrap();
    append(
        &s,
        "configuration",
        "a",
        "host",
        json!({"label":"Private host","hostname":"private.invalid"}),
    );
    append(
        &s,
        "credentials",
        "a",
        "host",
        json!({"password":"fixture-first-password"}),
    );
    append(
        &s,
        "credentials",
        "b",
        "host",
        json!({"password":"fixture-second-password"}),
    );
    let old = describe(&s, "credentials", "hosts/host");
    let text = old.to_string();
    assert!(!text.contains("fixture-first-password") && !text.contains("fixture-second-password"));
    assert_eq!(old["title"], "主机：Private host");
    let dot = old["details"][0]["candidates"][0]["dot"].clone();
    let mut request = json!({"scope":"credentials","id":"hosts/host","field":"password","dot":dot,"revision":old["revision"]});
    assert_eq!(
        conflicts::preview(&s, &request).unwrap_err().code,
        "syncConfirmation"
    );
    request["reveal"] = json!(true);
    assert_eq!(
        conflicts::preview(&s, &request).unwrap()["display"],
        "fixture-first-password"
    );
    append(
        &s,
        "credentials",
        "c",
        "host",
        json!({"password":"fixture-third-password"}),
    );
    assert_eq!(
        conflicts::preview(&s, &request).unwrap_err().code,
        "syncConflict"
    );
    assert_eq!(
        conflicts::check_revision(&s, &request, &s.state("credentials").unwrap(), "hosts/host")
            .unwrap_err()
            .code,
        "syncConflict"
    );
    assert!(s.state("credentials").unwrap().records["hosts/host"].conflicted());
}
#[test]
fn legacy_sources_are_not_invented_and_delete_edit_details_remain_visible() {
    let f = Fixture::new();
    let v = f.peer("Fixture");
    let s = Store::new(&v).unwrap();
    let a = model::Operation {
        version: 1,
        library: f.library.clone(),
        scope: "configuration".into(),
        dot: model::Dot {
            writer: "legacy".into(),
            seq: 1,
        },
        basis: Vector::new(),
        collection: "hosts".into(),
        record: "host".into(),
        source: None,
        action: Action::Patch {
            fields: BTreeMap::from([("hostname".into(), json!("old.invalid"))]),
        },
    };
    s.receive(&a, true).unwrap();
    append(
        &s,
        "configuration",
        "b",
        "host",
        json!({"hostname":"new.invalid"}),
    );
    let result = describe(&s, "configuration", "hosts/host");
    assert!(result.to_string().contains("旧版本：未记录来源设备"));
    s.append(
        "configuration",
        "delete",
        &Vector::new(),
        "hosts",
        "host",
        Action::Delete {
            recovery: json!({"hostname":"old.invalid"}),
            retention_days: Some(30),
            deleted_at: "2026-11-13T00:00:00Z".into(),
        },
    )
    .unwrap();
    let result = describe(&s, "configuration", "hosts/host");
    assert_eq!(result["deleted"], true);
    assert_eq!(result["details"][0]["label"], "主机地址 / IP");
    assert_eq!(result["deletions"].as_array().unwrap().len(), 1);
}
#[test]
fn legacy_operation_bytes_and_hashes_stay_stable_without_optional_source() {
    let raw = json!({"version":1,"library":"test","scope":"configuration","dot":{"writer":"a","seq":1},"basis":{},"collection":"hosts","record":"h","action":"patch","fields":{"label":"hello"}});
    let op: model::Operation = serde_json::from_value(raw.clone()).unwrap();
    assert_eq!(serde_json::to_value(&op).unwrap(), raw);
}
