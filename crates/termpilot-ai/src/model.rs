use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Protocol {
    #[default]
    Chat,
    Responses,
    Anthropic,
    Google,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Provider {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub protocol: Protocol,
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub headers: BTreeMap<String, String>,
    pub proxy: String,
    pub verify_tls: bool,
    pub parameters: Value,
    pub context_window: usize,
    pub enabled: bool,
}
impl Default for Provider {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: "OpenAI".into(),
            kind: "openai".into(),
            protocol: Protocol::Chat,
            base_url: "https://api.openai.com/v1".into(),
            api_key: String::new(),
            model: String::new(),
            headers: BTreeMap::new(),
            proxy: String::new(),
            verify_tls: true,
            parameters: json!({}),
            context_window: 32768,
            enabled: true,
        }
    }
}
#[derive(Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentConfig {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub executable: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: String,
    pub model: String,
    pub endpoint: String,
    pub config_directory: String,
    pub settings_file: String,
    pub auth_mode: String,
    pub api_key: String,
    pub base_url: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub providers: Vec<Provider>,
    pub agents: Vec<AgentConfig>,
    pub selected: String,
    pub mode: String,
    pub max_iterations: usize,
    pub search: Value,
    pub quick_messages: Vec<Value>,
    pub pinned_models: Vec<String>,
    pub command_timeout: u64,
    pub command_blacklist: Vec<String>,
    pub selection_shortcut: bool,
    pub tool_access: ToolAccess,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToolAccess {
    pub mode: String,
    pub enabled: bool,
    pub availability: String,
    pub idle_minutes: u64,
    pub activate_on_host_open: bool,
}
impl Default for ToolAccess {
    fn default() -> Self {
        Self {
            mode: "mcp".into(),
            enabled: false,
            availability: "temporary".into(),
            idle_minutes: 10,
            activate_on_host_open: true,
        }
    }
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            providers: vec![],
            agents: vec![],
            selected: String::new(),
            mode: "confirm".into(),
            max_iterations: 20,
            search: json!({"enabled":false,"kind":"tavily","maxResults":5}),
            quick_messages: vec![],
            pinned_models: vec![],
            command_timeout: 60,
            command_blacklist: crate::settings::default_blacklist(),
            selection_shortcut: true,
            tool_access: ToolAccess::default(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Message {
    #[serde(default)]
    pub id: String,
    pub role: String,
    pub content: String,
    pub calls: Vec<Call>,
    pub call_id: String,
    pub name: String,
    pub images: Vec<Value>,
    pub provider_data: Value,
}
impl Default for Message {
    fn default() -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            role: String::new(),
            content: String::new(),
            calls: vec![],
            call_id: String::new(),
            name: String::new(),
            images: vec![],
            provider_data: Value::Null,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Call {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub title: String,
    pub scope: String,
    pub agent: String,
    #[serde(default)]
    pub model: String,
    pub messages: Vec<Message>,
    pub draft: String,
    pub attachments: Vec<Value>,
    pub skills: Vec<String>,
    pub external_id: Option<String>,
    pub status: String,
    pub updated: u64,
    pub usage: Value,
}
impl Conversation {
    pub fn new(scope: String, agent: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            title: "新对话".into(),
            scope,
            agent,
            model: String::new(),
            messages: vec![],
            draft: String::new(),
            attachments: vec![],
            skills: vec![],
            external_id: None,
            status: "idle".into(),
            updated: now(),
            usage: Value::Null,
        }
    }
}
pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}
pub fn presets() -> Value {
    json!([
        {"kind":"openai","name":"OpenAI","protocol":"chat","baseUrl":"https://api.openai.com/v1"},
        {"kind":"anthropic","name":"Anthropic","protocol":"anthropic","baseUrl":"https://api.anthropic.com/v1"},
        {"kind":"google","name":"Google AI","protocol":"google","baseUrl":"https://generativelanguage.googleapis.com/v1beta"},
        {"kind":"ollama","name":"Ollama","protocol":"chat","baseUrl":"http://localhost:11434/v1"},
        {"kind":"openrouter","name":"OpenRouter","protocol":"chat","baseUrl":"https://openrouter.ai/api/v1"},
        {"kind":"qwen","name":"Qwen","protocol":"chat","baseUrl":"https://dashscope.aliyuncs.com/compatible-mode/v1"},
        {"kind":"deepseek","name":"DeepSeek","protocol":"chat","baseUrl":"https://api.deepseek.com/v1"},
        {"kind":"kimi","name":"Kimi","protocol":"chat","baseUrl":"https://api.moonshot.cn/v1"},
        {"kind":"zhipu","name":"Zhipu","protocol":"chat","baseUrl":"https://open.bigmodel.cn/api/paas/v4"},
        {"kind":"doubao","name":"Doubao","protocol":"chat","baseUrl":"https://ark.cn-beijing.volces.com/api/v3"},
        {"kind":"mimo","name":"Xiaomi MiMo","protocol":"chat","baseUrl":"https://api.xiaomimimo.com/v1"},
        {"kind":"custom","name":"Custom","protocol":"chat","baseUrl":""}
    ])
}
