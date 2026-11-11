//! Script dialogs normalize and validate in Rust, independently of native widgets.
use crate::{model::text, Runtime};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Map, Value};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;
pub fn visible(field: &Value, values: &Value) -> bool {
    let condition = &field["visibleWhen"];
    if condition.is_null() {
        return true;
    }
    let value = &values[text(condition, "field")];
    if let Some(expected) = condition.get("equals") {
        return value == expected;
    }
    if let Some(expected) = condition.get("notEquals") {
        return value != expected;
    }
    let truth = match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::String(s) => !s.is_empty(),
        Value::Number(n) => n.as_f64() != Some(0.),
        _ => true,
    };
    if condition["falsy"] == true {
        !truth
    } else {
        truth
    }
}
pub fn normalize(method: &str, args: &Value) -> Result<Value> {
    let mut spec = if method == "dialog.form" {
        args[0].clone()
    } else {
        let kind = match method {
            "dialog.checkbox" | "dialog.confirm" => "checkbox",
            "dialog.select" => "select",
            "dialog.radio" => "radio",
            _ => "text",
        };
        let options = if ["select", "radio"].contains(&kind) {
            args[1].clone()
        } else {
            Value::Null
        };
        let default = if !options.is_null() {
            args[2].clone()
        } else {
            args[1].clone()
        };
        json!({"title":args[0],"fields":if method=="dialog.alert"{json!([])}else{json!([{"name":"value","type":kind,"label":args[0],"options":options,"default":default}])}})
    };
    let fields = spec["fields"]
        .as_array_mut()
        .context("Dialog fields must be an array")?;
    ensure!(fields.len() <= 64, "Dialog field limit exceeded");
    let mut names = vec![];
    for field in fields {
        let name = text(field, "name").to_owned();
        ensure!(
            !name.is_empty()
                && !names.contains(&name)
                && !["__proto__", "prototype", "constructor"].contains(&name.as_str()),
            "Invalid or duplicate dialog field name"
        );
        if !field["visibleWhen"].is_null() {
            ensure!(
                names
                    .iter()
                    .any(|n| n == text(&field["visibleWhen"], "field")),
                "Dialog condition must reference an earlier field"
            );
        }
        names.push(name);
        let kind = field["type"].as_str().unwrap_or("text").to_owned();
        ensure!(
            ["text", "password", "textarea", "checkbox", "number", "select", "radio"]
                .contains(&kind.as_str()),
            "Unsupported dialog field type"
        );
        field["type"] = json!(kind);
        if field["required"].is_null() {
            field["required"] = json!(kind != "checkbox");
        }
        if ["select", "radio"].contains(&kind.as_str()) {
            let options = field["options"]
                .as_array_mut()
                .context("Choice options are required")?;
            ensure!(
                !options.is_empty() && options.len() <= 128,
                "Invalid choice count"
            );
            let mut values = vec![];
            for option in options {
                if option.is_string() {
                    *option = json!({"label":option.clone(),"value":option.clone()});
                }
                let value = text(option, "value").to_owned();
                ensure!(
                    !value.is_empty() && !values.contains(&value),
                    "Choice values must be nonempty and unique"
                );
                values.push(value);
            }
        }
        if kind == "number" {
            for key in ["min", "max", "step"] {
                if let Some(value) = field.get(key) {
                    ensure!(value.is_number(), "Number constraints must be numeric");
                }
            }
            if let Some(step) = field["step"].as_f64() {
                ensure!(step > 0., "Number step must be positive");
            }
        }
    }
    Ok(spec)
}
pub fn validate(spec: &Value, values: &Value) -> Result<Value> {
    ensure!(
        values.is_object(),
        "Dialog response values must be an object"
    );
    let mut result = Map::new();
    let mut conditions = values.clone();
    for field in spec["fields"].as_array().context("Missing fields")? {
        let name = text(field, "name");
        if !visible(field, &conditions) {
            conditions.as_object_mut().map(|m| m.remove(name));
            continue;
        }
        let value = &values[name];
        let required = field["required"] == true;
        let converted = match text(field, "type") {
            "checkbox" => {
                let value = value.as_bool().unwrap_or(false);
                ensure!(!required || value, "{name} must be checked");
                json!(value)
            }
            "number" => {
                if value.is_null() || value == "" {
                    ensure!(!required, "{name} is required");
                    continue;
                }
                let number = value
                    .as_f64()
                    .or_else(|| value.as_str().and_then(|s| s.parse::<f64>().ok()))
                    .context(format!("{name} must be a number"))?;
                ensure!(number.is_finite(), "{name} must be finite");
                if let Some(min) = field["min"].as_f64() {
                    ensure!(number >= min, "{name} is below its minimum")
                };
                if let Some(max) = field["max"].as_f64() {
                    ensure!(number <= max, "{name} exceeds its maximum")
                };
                if let Some(step) = field["step"].as_f64() {
                    let count = (number - field["min"].as_f64().unwrap_or(0.)) / step;
                    ensure!(
                        (count - count.round()).abs() < 1e-8,
                        "{name} does not match its step"
                    )
                };
                json!(number)
            }
            kind => {
                let string = value.as_str().unwrap_or("");
                ensure!(!required || !string.is_empty(), "{name} is required");
                if ["select", "radio"].contains(&kind) && !string.is_empty() {
                    ensure!(
                        field["options"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|o| o["value"] == string && o["disabled"] != true),
                        "{name} has an unavailable choice"
                    );
                }
                json!(string)
            }
        };
        result.insert(name.into(), converted.clone());
        conditions[name] = converted;
    }
    Ok(Value::Object(result))
}
pub async fn request(
    rt: &Arc<Runtime>,
    conversation: &str,
    method: &str,
    args: &Value,
    cancel: &CancellationToken,
) -> Result<Value> {
    let mut spec = normalize(method, args)?;
    spec["kind"] = json!(method.trim_start_matches("dialog."));
    loop {
        let answer = rt.ask(conversation, "form", spec.clone(), cancel).await?;
        if method == "dialog.confirm" && answer["cancelled"] == true {
            return Ok(json!(false));
        }
        ensure!(answer["cancelled"] != true, "User cancelled dialog");
        match validate(&spec, &answer["values"]) {
            Ok(value) => {
                return Ok(if method == "dialog.form" {
                    value
                } else {
                    value["value"].clone()
                })
            }
            Err(error) => {
                spec["error"] = json!(error.to_string());
                spec["values"] = answer["values"].clone();
            }
        }
    }
}
