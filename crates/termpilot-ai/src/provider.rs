use crate::model::{text, Call, Message, Protocol, Provider};
use anyhow::{bail, ensure, Context, Result};
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::{collections::BTreeMap, time::Duration};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub fn client(p: &Provider) -> Result<reqwest::Client> {
    let url = reqwest::Url::parse(&p.base_url).context("Invalid provider URL")?;
    ensure!(
        ["https", "http"].contains(&url.scheme())
            && url.username().is_empty()
            && url.password().is_none(),
        "Provider URL must be HTTP(S) without embedded credentials"
    );
    let mut b = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(300))
        .redirect(reqwest::redirect::Policy::none())
        .danger_accept_invalid_certs(!p.verify_tls);
    if !p.proxy.is_empty() {
        b = b.proxy(reqwest::Proxy::all(&p.proxy).context("Invalid provider proxy")?);
    }
    b.build().context("Unable to initialize provider transport")
}
fn request(p: &Provider, c: &reqwest::Client, path: &str) -> Result<reqwest::RequestBuilder> {
    let mut r = c.post(format!("{}{path}", p.base_url.trim_end_matches('/')));
    for (k, v) in &p.headers {
        r = r.header(
            reqwest::header::HeaderName::from_bytes(k.as_bytes()).context("Invalid header name")?,
            reqwest::header::HeaderValue::from_str(v).context("Invalid header value")?,
        );
    }
    if !p.api_key.is_empty() {
        r = match p.protocol {
            Protocol::Anthropic => r.header("x-api-key", &p.api_key),
            Protocol::Google => r.header("x-goog-api-key", &p.api_key),
            _ => r.bearer_auth(&p.api_key),
        };
    }
    if p.protocol == Protocol::Anthropic {
        r = r.header("anthropic-version", "2023-06-01");
    }
    Ok(r)
}
fn schema(t: &Value) -> Value {
    json!({"type":"object","properties":t["inputSchema"]["properties"],"required":t["inputSchema"]["required"],"additionalProperties":false})
}
pub fn body(p: &Provider, messages: &[Message], tools: &[Value]) -> Result<(String, Value)> {
    ensure!(!p.model.trim().is_empty(), "Select a model before sending");
    let system = messages
        .iter()
        .filter(|m| m.role == "system")
        .map(|m| m.content.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let (path, mut body) = match p.protocol {
        Protocol::Chat => {
            let ms:Vec<Value>=messages.iter().map(|m|{
                let mut v=json!({"role":m.role,"content":m.content});
                if !m.images.is_empty(){let mut parts=vec![json!({"type":"text","text":m.content})];parts.extend(m.images.iter().map(|i|json!({"type":"image_url","image_url":{"url":i["url"]}})));v["content"]=json!(parts);}
                if m.role=="tool" {v["tool_call_id"]=json!(m.call_id);}
                if !m.calls.is_empty(){v["tool_calls"]=json!(m.calls.iter().map(|c|json!({"id":c.id,"type":"function","function":{"name":c.name,"arguments":c.arguments.to_string()}})).collect::<Vec<_>>());}v
            }).collect();
            let mut b = json!({"model":p.model,"messages":ms,"stream":true,"stream_options":{"include_usage":true}});
            if !tools.is_empty() {
                b["tools"]=json!(tools.iter().map(|t|json!({"type":"function","function":{"name":t["name"],"description":t["description"],"parameters":schema(t)}})).collect::<Vec<_>>());
            }
            ("/chat/completions".into(), b)
        }
        Protocol::Responses => {
            let mut input = vec![];
            for m in messages.iter().filter(|m| m.role != "system") {
                if m.role == "tool" {
                    input.push(json!({"type":"function_call_output","call_id":m.call_id,"output":m.content}));
                } else if let Some(items) = m.provider_data.as_array() {
                    input.extend(items.clone());
                } else {
                    let content = if m.images.is_empty() {
                        json!(m.content)
                    } else {
                        let mut parts = vec![json!({"type":"input_text","text":m.content})];
                        parts.extend(
                            m.images
                                .iter()
                                .map(|i| json!({"type":"input_image","image_url":i["url"]})),
                        );
                        json!(parts)
                    };
                    input.push(json!({"role":m.role,"content":content}));
                    for c in &m.calls {
                        input.push(json!({"type":"function_call","call_id":c.id,"name":c.name,"arguments":c.arguments.to_string()}));
                    }
                }
            }
            (
                "/responses".into(),
                json!({"model":p.model,"instructions":system,"input":input,"stream":true,"store":false,"tools":tools.iter().map(|t|json!({"type":"function","name":t["name"],"description":t["description"],"parameters":schema(t),"strict":false})).collect::<Vec<_>>()}),
            )
        }
        Protocol::Anthropic => {
            let mut ms: Vec<Value> = vec![];
            for m in messages.iter().filter(|m| m.role != "system") {
                let mut parts = vec![];
                if m.role == "tool" {
                    parts.push(
                        json!({"type":"tool_result","tool_use_id":m.call_id,"content":m.content}),
                    );
                } else if let Some(raw) = m.provider_data.as_array() {
                    parts = raw.clone();
                } else {
                    if !m.content.is_empty() {
                        parts.push(json!({"type":"text","text":m.content}));
                    }
                    for i in &m.images {
                        let u = text(i, "url");
                        let (mime, data) = u
                            .strip_prefix("data:")
                            .and_then(|x| x.split_once(";base64,"))
                            .context("Anthropic images must be attached data")?;
                        parts.push(json!({"type":"image","source":{"type":"base64","media_type":mime,"data":data}}));
                    }
                    for c in &m.calls {
                        parts.push(
                            json!({"type":"tool_use","id":c.id,"name":c.name,"input":c.arguments}),
                        );
                    }
                }
                let role = if m.role == "tool" { "user" } else { &m.role };
                if let Some(last) = ms.last_mut().filter(|v| v["role"] == role) {
                    last["content"].as_array_mut().unwrap().extend(parts);
                } else {
                    ms.push(json!({"role":role,"content":parts}));
                }
            }
            (
                "/messages".into(),
                json!({"model":p.model,"system":system,"messages":ms,"max_tokens":4096,"stream":true,"tools":tools.iter().map(|t|json!({"name":t["name"],"description":t["description"],"input_schema":schema(t)})).collect::<Vec<_>>()}),
            )
        }
        Protocol::Google => {
            ensure!(
                p.model
                    .chars()
                    .all(|c| c.is_alphanumeric() || "-_.".contains(c)),
                "Invalid Google model ID"
            );
            let mut ms: Vec<Value> = vec![];
            for m in messages.iter().filter(|m| m.role != "system") {
                let parts = if m.role == "tool" {
                    vec![
                        json!({"functionResponse":{"name":m.name,"response":{"result":m.content}}}),
                    ]
                } else if let Some(raw) = m.provider_data.as_array() {
                    raw.clone()
                } else {
                    let mut parts = vec![];
                    if !m.content.is_empty() {
                        parts.push(json!({"text":m.content}));
                    }
                    for i in &m.images {
                        let (mime, data) = text(i, "url")
                            .strip_prefix("data:")
                            .and_then(|x| x.split_once(";base64,"))
                            .context("Google images must be attached data")?;
                        parts.push(json!({"inlineData":{"mimeType":mime,"data":data}}));
                    }
                    for c in &m.calls {
                        parts.push(json!({"functionCall":{"name":c.name,"args":c.arguments}}));
                    }
                    parts
                };
                let role = if m.role == "assistant" {
                    "model"
                } else {
                    "user"
                };
                if let Some(last) = ms.last_mut().filter(|v| v["role"] == role) {
                    last["parts"].as_array_mut().unwrap().extend(parts);
                } else {
                    ms.push(json!({"role":role,"parts":parts}));
                }
            }
            let mut b = json!({"systemInstruction":{"parts":[{"text":system}]},"contents":ms});
            if !tools.is_empty() {
                b["tools"] = json!([{"functionDeclarations":tools.iter().map(|t|json!({"name":t["name"],"description":t["description"],"parameters":t["inputSchema"]})).collect::<Vec<_>>()}]);
            }
            (
                format!("/models/{}:streamGenerateContent?alt=sse", p.model),
                b,
            )
        }
    };
    if let Some(params) = p.parameters.as_object() {
        for (key, v) in params {
            if [
                "max_tokens",
                "max_output_tokens",
                "max_completion_tokens",
                "temperature",
                "top_p",
                "frequency_penalty",
                "presence_penalty",
            ]
            .contains(&key.as_str())
            {
                let number = v
                    .as_f64()
                    .context(format!("Parameter {key} must be numeric"))?;
                let valid = match key.as_str() {
                    "temperature" => (0.0..=2.0).contains(&number),
                    "top_p" => (0.0..=1.0).contains(&number),
                    "frequency_penalty" | "presence_penalty" => (-2.0..=2.0).contains(&number),
                    _ => number >= 1.0 && number.fract() == 0.0,
                };
                ensure!(valid, "Parameter {key} is outside its supported range");
            }
            // Native editors expose the same familiar numeric fields regardless
            // of wire format; translate names here, shared across platforms.
            let translated;
            let key = if key == "max_tokens" {
                translated = match p.protocol {
                    Protocol::Chat => "max_tokens",
                    Protocol::Responses => "max_output_tokens",
                    _ => "max_tokens",
                }
                .to_string();
                &translated
            } else {
                key
            };
            if p.protocol == Protocol::Google
                && ["max_tokens", "temperature", "top_p"].contains(&key.as_str())
            {
                if body["generationConfig"].is_null() {
                    body["generationConfig"] = json!({});
                }
                body["generationConfig"][match key.as_str() {
                    "max_tokens" => "maxOutputTokens",
                    "top_p" => "topP",
                    _ => "temperature",
                }] = v.clone();
                continue;
            }
            let allowed = match p.protocol {
                Protocol::Chat => [
                    "temperature",
                    "top_p",
                    "presence_penalty",
                    "frequency_penalty",
                    "max_completion_tokens",
                    "max_tokens",
                    "reasoning_effort",
                ]
                .contains(&key.as_str()),
                Protocol::Responses => ["temperature", "top_p", "max_output_tokens", "reasoning"]
                    .contains(&key.as_str()),
                Protocol::Anthropic => {
                    ["temperature", "top_p", "max_tokens", "thinking"].contains(&key.as_str())
                }
                Protocol::Google => ["generationConfig"].contains(&key.as_str()),
            };
            ensure!(
                allowed,
                "Parameter {key} is not supported by the selected wire protocol"
            );
            body[key] = v.clone();
        }
    }
    Ok((path, body))
}

/// Bytes are decoded after complete SSE lines, preserving split UTF-8 sequences.
#[derive(Default)]
pub struct Sse {
    pending: Vec<u8>,
    data: Vec<String>,
}
impl Sse {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<String>> {
        self.pending.extend(bytes);
        ensure!(
            self.pending.len() <= 8 * 1024 * 1024,
            "Provider event exceeds 8 MiB"
        );
        let mut events = vec![];
        while let Some(n) = self.pending.iter().position(|b| *b == b'\n') {
            let raw: Vec<u8> = self.pending.drain(..=n).collect();
            let line = std::str::from_utf8(&raw[..n])?.trim_end_matches('\r');
            if line.is_empty() {
                if !self.data.is_empty() {
                    events.push(self.data.join("\n"));
                    self.data.clear();
                }
            } else if let Some(value) = line.strip_prefix("data:") {
                self.data
                    .push(value.strip_prefix(' ').unwrap_or(value).to_owned());
            }
            ensure!(
                self.data.iter().map(String::len).sum::<usize>() <= 8 * 1024 * 1024,
                "Provider event exceeds 8 MiB"
            );
        }
        Ok(events)
    }
}
#[derive(Default)]
pub struct Accumulator {
    pub message: Message,
    pub usage: Value,
    calls: BTreeMap<usize, (String, String, String)>,
    blocks: BTreeMap<usize, Value>,
    received_bytes: usize,
    pub finished: bool,
}
impl Accumulator {
    pub fn accept(&mut self, p: &Protocol, v: &Value) -> Result<Vec<Value>> {
        self.received_bytes = self.received_bytes.saturating_add(v.to_string().len());
        ensure!(
            self.received_bytes <= 16 * 1024 * 1024,
            "Model stream exceeds aggregate size limit"
        );
        let mut out = vec![];
        let mut delta = String::new();
        let mut reasoning = String::new();
        ensure!(v.get("error").is_none(), "Model service returned an error");
        match p {
            Protocol::Chat => {
                let d = &v["choices"][0]["delta"];
                delta = text(d, "content").into();
                reasoning = text(d, "reasoning_content").into();
                if let Some(cs) = d["tool_calls"].as_array() {
                    for c in cs {
                        let i = c["index"].as_u64().context("Missing tool call index")? as usize;
                        let e = self.calls.entry(i).or_default();
                        if let Some(id) = c["id"].as_str() {
                            e.0 = id.into();
                        }
                        if let Some(n) = c["function"]["name"].as_str() {
                            e.1.push_str(n);
                        }
                        if let Some(a) = c["function"]["arguments"].as_str() {
                            e.2.push_str(a);
                        }
                    }
                }
                let finish = text(&v["choices"][0], "finish_reason");
                if !finish.is_empty() {
                    ensure!(
                        ["stop", "tool_calls"].contains(&finish),
                        "Model output incomplete: {finish}"
                    );
                    self.finished = true;
                }
                if !v["usage"].is_null() {
                    self.usage = v["usage"].clone();
                }
            }
            Protocol::Responses => match text(v, "type") {
                "response.output_text.delta" => delta = text(v, "delta").into(),
                "response.reasoning_summary_text.delta" => reasoning = text(v, "delta").into(),
                "response.completed" => {
                    let r = &v["response"];
                    self.message.provider_data = r["output"].clone();
                    self.usage = r["usage"].clone();
                    self.finished = true;
                    if let Some(items) = r["output"].as_array() {
                        for item in items {
                            if item["type"] == "function_call" {
                                self.message.calls.push(Call {
                                    id: text(item, "call_id").into(),
                                    name: text(item, "name").into(),
                                    arguments: serde_json::from_str(text(item, "arguments"))?,
                                });
                            }
                        }
                    }
                }
                "response.failed" | "response.incomplete" | "error" => {
                    bail!("Model response failed or incomplete")
                }
                _ => {}
            },
            Protocol::Anthropic => match text(v, "type") {
                "message_start" => self.usage = v["message"]["usage"].clone(),
                "content_block_start" => {
                    let i = v["index"].as_u64().unwrap_or(0) as usize;
                    let b = &v["content_block"];
                    self.blocks.insert(i, b.clone());
                    if b["type"] == "tool_use" {
                        self.calls.insert(
                            i,
                            (text(b, "id").into(), text(b, "name").into(), String::new()),
                        );
                    }
                }
                "content_block_delta" => {
                    let d = &v["delta"];
                    let i = v["index"].as_u64().unwrap_or(0) as usize;
                    match text(d, "type") {
                        "text_delta" => delta = text(d, "text").into(),
                        "thinking_delta" => reasoning = text(d, "thinking").into(),
                        "input_json_delta" => self
                            .calls
                            .entry(i)
                            .or_default()
                            .2
                            .push_str(text(d, "partial_json")),
                        "signature_delta" => {
                            if let Some(b) = self.blocks.get_mut(&i) {
                                let mut s = text(b, "signature").to_owned();
                                s.push_str(text(d, "signature"));
                                b["signature"] = json!(s);
                            }
                        }
                        _ => {}
                    }
                    if let Some(b) = self.blocks.get_mut(&i) {
                        for (key, part) in [("text", &delta), ("thinking", &reasoning)] {
                            if !part.is_empty() {
                                let mut s = text(b, key).to_owned();
                                s.push_str(part);
                                b[key] = json!(s);
                            }
                        }
                    }
                }
                "message_delta" => {
                    let reason = text(&v["delta"], "stop_reason");
                    ensure!(
                        ["", "end_turn", "tool_use", "stop_sequence"].contains(&reason),
                        "Model output incomplete: {reason}"
                    );
                    if let Some(u) = v["usage"].as_object() {
                        for (k, x) in u {
                            self.usage[k] = x.clone();
                        }
                    }
                }
                "message_stop" => self.finished = true,
                "error" => bail!("Model service returned an error"),
                _ => {}
            },
            Protocol::Google => {
                if let Some(parts) = v["candidates"][0]["content"]["parts"].as_array() {
                    for part in parts {
                        if part["thought"] == true {
                            reasoning.push_str(text(part, "text"));
                        } else {
                            delta.push_str(text(part, "text"));
                        }
                        if let Some(c) = part.get("functionCall") {
                            self.message.calls.push(Call {
                                id: uuid::Uuid::new_v4().to_string(),
                                name: text(c, "name").into(),
                                arguments: c["args"].clone(),
                            });
                        }
                        let idx = self.blocks.len();
                        self.blocks.insert(idx, part.clone());
                    }
                }
                let finish = text(&v["candidates"][0], "finishReason");
                if !finish.is_empty() {
                    ensure!(finish == "STOP", "Model output incomplete: {finish}");
                    self.finished = true;
                }
                if !v["usageMetadata"].is_null() {
                    self.usage = v["usageMetadata"].clone();
                }
                ensure!(
                    v["promptFeedback"]["blockReason"].is_null(),
                    "Model blocked the prompt"
                );
            }
        }
        self.message.content.push_str(&delta);
        ensure!(
            self.calls.len() <= 128 && self.message.calls.len() <= 128,
            "Model tool call limit exceeded"
        );
        ensure!(
            self.message.content.len() <= 4 * 1024 * 1024,
            "Model output limit exceeded"
        );
        if !delta.is_empty() {
            out.push(json!({"type":"delta","text":delta}));
        }
        if !reasoning.is_empty() {
            out.push(json!({"type":"reasoning","text":reasoning}));
        }
        Ok(out)
    }
    pub fn finish(mut self, p: &Protocol) -> Result<(Message, Value)> {
        ensure!(self.finished, "Provider stream ended before completion");
        for (i, (id, name, args)) in self.calls {
            ensure!(!id.is_empty() && !name.is_empty(), "Invalid tool call");
            let arguments = if args.is_empty() {
                self.blocks
                    .get(&i)
                    .map(|b| b["input"].clone())
                    .unwrap_or(json!({}))
            } else {
                serde_json::from_str(&args).context("Invalid tool arguments")?
            };
            if let Some(b) = self.blocks.get_mut(&i) {
                b["input"] = arguments.clone();
            }
            self.message.calls.push(Call {
                id,
                name,
                arguments,
            });
        }
        if [Protocol::Anthropic, Protocol::Google].contains(p) {
            self.message.provider_data = json!(self.blocks.into_values().collect::<Vec<_>>());
        }
        self.message.role = "assistant".into();
        Ok((self.message, self.usage))
    }
}
pub async fn complete(
    p: &Provider,
    messages: &[Message],
    tools: &[Value],
    events: &mpsc::Sender<Value>,
    cancel: &CancellationToken,
) -> Result<(Message, Value)> {
    let c = client(p)?;
    let (path, body) = body(p, messages, tools)?;
    let response = tokio::select! {_=cancel.cancelled()=>bail!("Cancelled"),r=request(p,&c,&path)?.json(&body).send()=>r.map_err(|_|anyhow::anyhow!("Model connection failed; check endpoint, proxy and TLS"))?};
    ensure!(
        response.status().is_success(),
        "Model service HTTP {}",
        response.status().as_u16()
    );
    let mut stream = response.bytes_stream();
    let mut sse = Sse::default();
    let mut acc = Accumulator::default();
    loop {
        let next = tokio::select! {_=cancel.cancelled()=>bail!("Cancelled"),n=stream.next()=>n};
        let Some(bytes) = next else { break };
        let bytes = bytes.context("Model stream interrupted")?;
        for line in sse.push(&bytes)? {
            if line == "[DONE]" {
                break;
            }
            let value: Value = serde_json::from_str(&line).context("Invalid provider event")?;
            for event in acc.accept(&p.protocol, &value)? {
                tokio::select! {_=cancel.cancelled()=>bail!("Cancelled"),r=events.send(event)=>r.context("AI event receiver closed")?};
            }
        }
    }
    acc.finish(&p.protocol)
}
/// Normalize discovery once for both native settings and chat selectors.
pub fn model_ids(value: &Value, protocol: &Protocol) -> Result<Vec<String>> {
    let entries = value["data"]
        .as_array()
        .or_else(|| value["models"].as_array())
        .or_else(|| value.as_array())
        .context("模型接口未返回可识别的列表，请检查 Base URL；也可手动填写模型 ID")?;
    let mut ids = std::collections::BTreeSet::new();
    for entry in entries {
        let Some(id) = entry
            .as_str()
            .or_else(|| entry["id"].as_str())
            .or_else(|| entry["name"].as_str())
            .or_else(|| entry["model"].as_str())
        else {
            continue;
        };
        let id = id.trim();
        let id = if matches!(protocol, Protocol::Google) {
            id.strip_prefix("models/").unwrap_or(id)
        } else {
            id
        };
        if !id.is_empty() {
            ids.insert(id.to_owned());
        }
    }
    ensure!(
        entries.is_empty() || !ids.is_empty(),
        "模型列表缺少模型 ID，也可手动填写"
    );
    Ok(ids.into_iter().collect())
}

pub async fn models(p: &Provider) -> Result<Value> {
    ensure!(
        !p.base_url.trim().is_empty(),
        "请先填写 Base URL，再获取模型列表"
    );
    tokio::time::timeout(Duration::from_secs(30), model_pages(p))
        .await
        .map_err(|_| anyhow::anyhow!("获取模型列表超时，请检查网络或代理后重试"))?
}
async fn model_pages(p: &Provider) -> Result<Value> {
    let c = client(p)?;
    let mut ids = std::collections::BTreeSet::new();
    let mut cursor = String::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut total_bytes = 0;
    for _ in 0..50 {
        let mut req = request(p, &c, "/models")?.build()?;
        *req.method_mut() = reqwest::Method::GET;
        if !cursor.is_empty() {
            req.url_mut().query_pairs_mut().append_pair(
                if matches!(p.protocol, Protocol::Google) {
                    "pageToken"
                } else {
                    "after_id"
                },
                &cursor,
            );
        }
        let r = c.execute(req).await.map_err(|_| {
            anyhow::anyhow!("无法获取模型列表，请检查 Base URL、网络、代理和 TLS 配置")
        })?;
        match r.status().as_u16() {
            401 | 403 => bail!(
                "模型列表认证失败（HTTP {}），请检查 API Key 与访问权限",
                r.status().as_u16()
            ),
            404 | 405 => bail!(
                "当前地址不支持模型列表（HTTP {}），请检查 Base URL；也可手动填写模型 ID",
                r.status().as_u16()
            ),
            429 => bail!("模型接口请求过于频繁（HTTP 429），请稍后刷新"),
            _ => ensure!(
                r.status().is_success(),
                "获取模型列表失败（HTTP {}）",
                r.status().as_u16()
            ),
        }
        let mut stream = r.bytes_stream();
        let mut bytes = vec![];
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| anyhow::anyhow!("模型列表传输中断，请刷新重试"))?;
            total_bytes += chunk.len();
            ensure!(
                total_bytes <= 4 * 1024 * 1024,
                "模型列表过大，请手动填写模型 ID"
            );
            bytes.extend(chunk);
        }
        let page: Value = serde_json::from_slice(&bytes)
            .context("模型接口返回的内容不是 JSON，请检查 Base URL")?;
        ids.extend(model_ids(&page, &p.protocol)?);
        cursor = match p.protocol {
            Protocol::Google => text(&page, "nextPageToken").into(),
            Protocol::Anthropic if page["has_more"] == true => {
                let id = text(&page, "last_id");
                ensure!(!id.is_empty(), "模型列表分页缺少游标，请手动填写模型 ID");
                id.into()
            }
            _ => String::new(),
        };
        if cursor.is_empty() {
            return Ok(
                json!({"modelIds": ids, "data": ids.iter().map(|id| json!({"id":id})).collect::<Vec<_>>()}),
            );
        }
        ensure!(
            seen.insert(cursor.clone()),
            "模型列表分页重复，请手动填写模型 ID"
        );
    }
    bail!("模型列表分页过多，请手动填写模型 ID")
}
