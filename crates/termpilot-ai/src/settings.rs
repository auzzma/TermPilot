//! Configuration shared by the native settings surfaces. Baseline: Netcatty 1.1.73.
use crate::model::{text, Settings};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};

pub fn default_blacklist() -> Vec<String> {
    [r"\brm\s+(?=[^\n;&|]*(?:-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\b|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*\b|-[a-zA-Z]*r[a-zA-Z]*\b[^\n;&|]*-[a-zA-Z]*f[a-zA-Z]*\b|-[a-zA-Z]*f[a-zA-Z]*\b[^\n;&|]*-[a-zA-Z]*r[a-zA-Z]*\b|--recursive\b[^\n;&|]*(?:--force\b|-[a-zA-Z]*f[a-zA-Z]*\b)|(?:--force\b|-[a-zA-Z]*f[a-zA-Z]*\b)[^\n;&|]*--recursive\b))",
     r"\bmkfs\.", r"\bdd\s+if=.*\s+of=/dev/", r"\b(shutdown|reboot|poweroff|halt)\b",
     r":\(\)\{\s*:\|:\&\s*\};:", r">\s*/dev/sd", r"\bchmod\s+(-[a-zA-Z]*R[a-zA-Z]*|--recursive)\s+777\s+/",
     r"\bmv\s+/\s", r":\s*>\s*/etc/", r"\bcurl\s+.*\|\s*\bsudo\s+\bbash\b", r"\bwget\s+.*\|\s*\bsudo\s+\bbash\b",
     r"base64.*\|.*(?:ba)?sh", r"\beval\b", r"\$\(", r"`.+`"].into_iter().map(str::to_owned).collect()
}

// JavaScript regex syntax includes lookahead in the baseline rules. A bounded
// QuickJS context keeps that syntax without depending on Node or an unbounded regex.
pub fn command_blocked(rules: &[String], command: Option<&str>) -> Result<bool> {
    ensure!(
        rules.len() <= 128 && rules.iter().all(|s| !s.is_empty() && s.len() <= 4096),
        "命令黑名单最多 128 条，每条 1–4096 字节"
    );
    let rt = rquickjs::Runtime::new()?;
    rt.set_memory_limit(16 * 1024 * 1024);
    rt.set_max_stack_size(512 * 1024);
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(200);
    rt.set_interrupt_handler(Some(Box::new(move || {
        std::time::Instant::now() >= deadline
    })));
    let ctx = rquickjs::Context::full(&rt)?;
    let source = format!("(() => {{ const rules = {}.map(s => new RegExp(s)); const command = {}; return command === null ? false : rules.some(r => r.test(command)); }})()", serde_json::to_string(rules)?, serde_json::to_string(&command)?);
    ctx.with(|ctx| ctx.eval::<bool, _>(source))
        .context("命令黑名单表达式无效或检查超时")
}

pub fn validate(s: &Settings) -> Result<()> {
    ensure!(
        (1..=86400).contains(&s.command_timeout),
        "命令超时必须为 1–86400 秒"
    );
    command_blocked(&s.command_blacklist, None)?;
    ensure!(
        ["mcp", "skills-cli"].contains(&s.tool_access.mode.as_str()),
        "无效的工具接入方式"
    );
    ensure!(
        ["temporary", "persistent"].contains(&s.tool_access.availability.as_str()),
        "无效的 MCP 可用模式"
    );
    ensure!(
        (1..=1440).contains(&s.tool_access.idle_minutes),
        "空闲超时必须为 1–1440 分钟"
    );
    if let Some(n) = s.search["maxResults"].as_u64() {
        ensure!((1..=20).contains(&n), "搜索结果数必须为 1–20");
    }
    if search_enabled(&s.search) {
        ensure!(
            ["tavily", "exa", "bocha", "zhipu", "searxng"].contains(&text(&s.search, "kind")),
            "请选择搜索供应商"
        );
    }
    Ok(())
}
pub fn search_enabled(v: &Value) -> bool {
    v["enabled"]
        .as_bool()
        .unwrap_or_else(|| !text(v, "apiKey").is_empty() || text(v, "kind") == "searxng")
}
pub fn metadata() -> Value {
    json!({"baseline":"Netcatty 1.1.73","tabs":["提供商","Agent","工具接入","网络搜索","安全"],"commandBlacklist":default_blacklist(),
        "searchProviders":[{"kind":"tavily","name":"Tavily","endpoint":"https://api.tavily.com"},{"kind":"exa","name":"Exa","endpoint":"https://api.exa.ai"},{"kind":"bocha","name":"Bocha","endpoint":"https://api.bochaai.com"},{"kind":"zhipu","name":"Zhipu","endpoint":"https://open.bigmodel.cn/api/paas/v4"},{"kind":"searxng","name":"SearXNG","endpoint":""}]})
}
