use crate::{
    connection::{Connection, CoreError},
    vault::model,
};
use serde_json::{json, Value};
pub fn resolve(request: &Value) -> Result<Value, CoreError> {
    let mut host = request["host"].clone();
    if !host.is_object() {
        return Err(CoreError::new("invalidHost", "Invalid host configuration."));
    }
    let find = |collection: &str, id: &str| {
        request[collection]
            .as_array()
            .into_iter()
            .flatten()
            .find(|v| v["id"].as_str().is_some_and(|s| s.eq_ignore_ascii_case(id)))
            .cloned()
    };
    if !request["proxyOnly"].as_bool().unwrap_or(false) {
        if let Some(id) = host["credentialID"].as_str() {
            let credential = find("credentials", id).ok_or(CoreError::new(
                "missingCredential",
                "The selected credential no longer exists.",
            ))?;
            if host["username"].as_str().unwrap_or("").trim().is_empty() {
                host["username"] = credential["username"].clone();
            }
            host["authentication"] = json!(if credential["kind"] == "identityKey" {
                "identityFile"
            } else {
                "password"
            });
            for (a, b) in [
                ("password", "password"),
                ("identityKey", "privateKey"),
                ("publicKey", "publicKey"),
                ("certificate", "certificate"),
                ("passphrase", "passphrase"),
            ] {
                host[a] = credential[b].clone();
            }
            host["identityFile"] = Value::Null;
            if host["elevationPassword"].is_null() {
                host["elevationPassword"] = credential["elevationPassword"].clone();
            }
        }
    }
    if request["credentialsOnly"].as_bool().unwrap_or(false) {
        return Ok(json!({"host":host}));
    }
    let mut proxy = if host["proxyConfiguration"].is_object() {
        host["proxyConfiguration"].clone()
    } else if let Some(id) = host["proxyProfileID"].as_str() {
        find("proxyProfiles", id).ok_or(CoreError::new(
            "missingProxy",
            "The selected proxy no longer exists.",
        ))?["configuration"]
            .clone()
    } else {
        Value::Null
    };
    if proxy.is_object() {
        let mut record = json!({"label":"proxy","configuration":proxy});
        model::validate("proxies", &mut record)?;
        proxy = record["configuration"].clone();
    }
    if let Some(id) = proxy["credentialID"].as_str() {
        let credential = find("credentials", id).ok_or(CoreError::new(
            "missingProxyCredential",
            "The selected proxy credential no longer exists.",
        ))?;
        if credential["kind"] != "password"
            || credential["password"].as_str().unwrap_or("").is_empty()
            || credential["username"]
                .as_str()
                .unwrap_or("")
                .trim()
                .is_empty()
        {
            return Err(CoreError::new(
                "invalidProxyCredential",
                "Proxy authentication requires a password credential.",
            ));
        }
        proxy["username"] = credential["username"].clone();
        proxy["password"] = credential["password"].clone();
    }
    host["proxyConfiguration"] = proxy;
    if request["validate"].as_bool().unwrap_or(false) {
        let protocol = request["protocol"].as_str().unwrap_or("ssh");
        let policy:Connection=serde_json::from_value(json!({"protocol":protocol,"host":host["hostname"],"port":host["port"],"username":host["username"],"proxy":host["proxyConfiguration"]})).map_err(|_|CoreError::new("invalidConnection","Invalid connection configuration."))?;
        policy.validate()?;
    }
    Ok(json!({"host":host}))
}
