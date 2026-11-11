use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
pub struct CoreError {
    pub code: &'static str,
    pub message: &'static str,
}
impl CoreError {
    pub fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message }
    }
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Protocol {
    Ssh,
    StandardVNC,
    HighPerformance,
    Rdp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub protocol: Protocol,
    pub host: String,
    pub port: u64,
    #[serde(default)]
    pub username: String,
    pub proxy: Option<Proxy>,
    #[serde(default)]
    pub proxy_required: bool,
}

#[derive(Deserialize)]
pub struct Proxy {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: u64,
    pub command: Option<String>,
}

pub fn validate_endpoint(host: &str, port: u64) -> Result<(), CoreError> {
    let host = host.trim();
    if host.is_empty()
        || host.len() > 253
        || host.starts_with('-')
        || host
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '/' | '\\' | '@'))
    {
        return Err(CoreError::new(
            "invalidHost",
            "Enter a valid hostname or IP address.",
        ));
    }
    if !(1..=65535).contains(&port) {
        return Err(CoreError::new(
            "invalidPort",
            "Port must be between 1 and 65535.",
        ));
    }
    Ok(())
}

impl Connection {
    pub fn validate(&self) -> Result<(), CoreError> {
        validate_endpoint(&self.host, self.port)?;
        if self.protocol != Protocol::StandardVNC && self.username.trim().is_empty() {
            return Err(CoreError::new("missingUsername", "Username is required."));
        }
        if self.protocol == Protocol::HighPerformance
            && (self.proxy.is_some() || self.proxy_required)
        {
            return Err(CoreError::new(
                "highPerformanceProxyUnsupported",
                "High Performance requires a direct or VPN/TUN connection.",
            ));
        }
        if self.proxy_required && self.proxy.is_none() {
            return Err(CoreError::new(
                "missingProxy",
                "The selected proxy is unavailable.",
            ));
        }
        if let Some(proxy) = &self.proxy {
            match proxy.kind.as_str() {
                "http" | "socks5" => validate_endpoint(&proxy.host, proxy.port)?,
                "command" if self.protocol == Protocol::Ssh => {
                    if proxy.command.as_deref().unwrap_or("").trim().is_empty() {
                        return Err(CoreError::new(
                            "missingProxyCommand",
                            "Proxy command is required.",
                        ));
                    }
                }
                _ => {
                    return Err(CoreError::new(
                        "unsupportedProxy",
                        "This proxy type is not supported by the selected protocol.",
                    ))
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn check(value: serde_json::Value) -> Result<(), CoreError> {
        serde_json::from_value::<Connection>(value)
            .unwrap()
            .validate()
    }
    #[test]
    fn proxy_failure_never_selects_direct_connection() {
        let result = check(
            json!({"protocol":"standardVNC","host":"mac.example","port":5900,"proxyRequired":true}),
        );
        assert_eq!(result.unwrap_err().code, "missingProxy");
    }
    #[test]
    fn protocol_specific_policy() {
        for kind in ["http", "socks5", "command"] {
            let proxy = json!({"type":kind,"host":"localhost","port":1080,"command":"proxy %h %p"});
            assert!(check(
                json!({"protocol":"ssh","host":"server","port":22,"username":"user","proxy":proxy})
            )
            .is_ok());
            assert_eq!(check(json!({"protocol":"highPerformance","host":"mac","port":5900,"username":"user","proxy":proxy})).unwrap_err().code,"highPerformanceProxyUnsupported");
            assert_eq!(check(json!({"protocol":"rdp","host":"windows","port":3389,"username":"DOMAIN\\user","proxy":proxy})).is_ok(), kind != "command");
            assert_eq!(
                check(json!({"protocol":"standardVNC","host":"mac","port":5900,"proxy":proxy}))
                    .is_ok(),
                kind != "command"
            );
        }
    }
    #[test]
    fn endpoints_reject_injection_and_accept_ipv6() {
        for host in [
            "",
            "-oProxyCommand=bad",
            "x\ny",
            "a/b",
            "vnc://x",
            "user@host",
            "a\0b",
            "a\\b",
        ] {
            assert!(validate_endpoint(host, 5900).is_err());
        }
        assert!(validate_endpoint("::1", 5900).is_ok());
        for port in [0, 65536, u64::MAX] {
            assert!(validate_endpoint("localhost", port).is_err());
        }
    }
}
