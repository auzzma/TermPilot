//! Platform-neutral chat projection. Stored conversations and tool permissions are unchanged.
use crate::{model::text, tools::redact};
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

pub fn markdown(source: &str) -> Value {
    let mut stack = vec![json!({"kind":"document","children":[]})];
    for event in Parser::new_ext(
        source,
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS,
    ) {
        match event {
            Event::Start(tag) => {
                let node = match tag {
                    Tag::Paragraph => json!({"kind":"paragraph"}),
                    Tag::Heading { level, .. } => json!({"kind":"heading","level":level as u8}),
                    Tag::BlockQuote(_) => json!({"kind":"quote"}),
                    Tag::CodeBlock(kind) => {
                        json!({"kind":"codeBlock","language":match kind {CodeBlockKind::Fenced(s)=>s.to_string(),_=>String::new()}})
                    }
                    Tag::List(start) => json!({"kind":"list","start":start}),
                    Tag::Item => json!({"kind":"item"}),
                    Tag::Table(alignments) => {
                        json!({"kind":"table","alignments":alignments.iter().map(|a|format!("{a:?}").to_lowercase()).collect::<Vec<_>>()})
                    }
                    Tag::TableHead => json!({"kind":"tableHead"}),
                    Tag::TableRow => json!({"kind":"tableRow"}),
                    Tag::TableCell => json!({"kind":"tableCell"}),
                    Tag::Strong => json!({"kind":"strong"}),
                    Tag::Emphasis => json!({"kind":"emphasis"}),
                    Tag::Strikethrough => json!({"kind":"strike"}),
                    Tag::Link { dest_url, .. } => json!({"kind":"link","url":safe_link(&dest_url)}),
                    // Do not fetch remote media or interpret raw HTML in model responses.
                    Tag::Image { .. } => json!({"kind":"image"}),
                    _ => json!({"kind":"group"}),
                };
                let mut node = node;
                node["children"] = json!([]);
                stack.push(node);
            }
            Event::End(_) => {
                if stack.len() > 1 {
                    let node = stack.pop().unwrap();
                    push(&mut stack, node);
                }
            }
            Event::Text(s) | Event::Html(s) | Event::InlineHtml(s) => {
                push(&mut stack, json!({"kind":"text","text":s.to_string()}))
            }
            Event::Code(s) => push(&mut stack, json!({"kind":"code","text":s.to_string()})),
            Event::SoftBreak | Event::HardBreak => {
                push(&mut stack, json!({"kind":"text","text":"\n"}))
            }
            Event::Rule => push(&mut stack, json!({"kind":"rule"})),
            Event::TaskListMarker(checked) => push(
                &mut stack,
                json!({"kind":"text","text":if checked {"☑ "} else {"☐ "}}),
            ),
            _ => {}
        }
    }
    let mut root = stack.remove(0);
    normalize_blocks(&mut root);
    root["children"].take()
}
// CommonMark tight lists omit paragraph events. Keep adjacent inline nodes on
// one native text line instead of turning every emphasis/code span into a row.
fn normalize_blocks(node: &mut Value) {
    let kind = text(node, "kind").to_owned();
    if let Some(children) = node["children"].as_array_mut() {
        for child in children.iter_mut() {
            normalize_blocks(child);
        }
        if ["document", "item", "quote", "group"].contains(&kind.as_str()) {
            let mut output = Vec::new();
            let mut inline = Vec::new();
            for child in std::mem::take(children) {
                if [
                    "text", "code", "strong", "emphasis", "strike", "link", "image",
                ]
                .contains(&text(&child, "kind"))
                {
                    inline.push(child);
                } else {
                    if !inline.is_empty() {
                        output.push(
                            json!({"kind":"paragraph","children":std::mem::take(&mut inline)}),
                        );
                    }
                    output.push(child);
                }
            }
            if !inline.is_empty() {
                output.push(json!({"kind":"paragraph","children":inline}));
            }
            *children = output;
        }
    }
}
fn push(stack: &mut [Value], node: Value) {
    stack.last_mut().unwrap()["children"]
        .as_array_mut()
        .unwrap()
        .push(node);
}
fn safe_link(url: &str) -> &str {
    if ["https://", "http://", "mailto:"]
        .iter()
        .any(|s| url.to_lowercase().starts_with(s))
    {
        url
    } else {
        ""
    }
}
fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(&redact(value.clone())).unwrap_or_default()
}
fn summary(name: &str, args: &Value) -> String {
    let command = match &args["command"] {
        Value::String(s) => s.clone(),
        Value::Array(a) => a
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    };
    if !command.is_empty() {
        return format!(
            "$ {}",
            command.split_whitespace().collect::<Vec<_>>().join(" ")
        );
    }
    let detail = ["path", "remotePath", "localPath", "query", "url"]
        .iter()
        .map(|k| text(args, k))
        .find(|s| !s.is_empty())
        .unwrap_or("");
    if detail.is_empty() {
        name.into()
    } else {
        format!("{name} · {detail}")
    }
}
fn result_state(content: &str) -> &'static str {
    if content.starts_with("Interrupted before") {
        return "interrupted";
    }
    let v: Value = serde_json::from_str(content).unwrap_or(Value::Null);
    if !v["error"].is_null()
        || v["ok"] == false
        || v["isError"] == true
        || v["code"].as_i64().is_some_and(|n| n != 0)
        || v["exitCode"].as_i64().is_some_and(|n| n != 0)
        || ["failed", "error"].contains(&text(&v, "status"))
    {
        "error"
    } else if text(&v, "status") == "running" {
        "background"
    } else {
        "completed"
    }
}
fn flush(rows: &mut Vec<Value>, tools: &mut Vec<Value>) {
    if tools.is_empty() {
        return;
    }
    rows.push(json!({"kind":"tools","id":format!("tools:{}",text(&tools[0],"id")),"tools":std::mem::take(tools)}));
}
pub fn render(params: &Value) -> Value {
    let empty = Vec::new();
    let messages = params["messages"].as_array().unwrap_or(&empty);
    let pending = params["interactions"].as_array().unwrap_or(&empty);
    let mut used = HashSet::new();
    let results: HashMap<&str, &Value> = messages
        .iter()
        .filter(|m| text(m, "role") == "tool" && !text(m, "callId").is_empty())
        .map(|m| (text(m, "callId"), m))
        .collect();
    let call_ids: HashSet<&str> = messages
        .iter()
        .flat_map(|m| m["calls"].as_array().unwrap_or(&empty))
        .map(|c| text(c, "id"))
        .collect();
    let mut rows = Vec::new();
    let mut tools = Vec::new();
    for (index, message) in messages.iter().enumerate() {
        let role = text(message, "role");
        let content = text(message, "content");
        if role == "tool" {
            if !call_ids.contains(text(message, "callId")) {
                tools.push(json!({"id":format!("orphan:{index}"),"name":text(message,"name"),"summary":text(message,"name"),"arguments":"","output":content,"state":result_state(content)}));
            }
            continue;
        }
        if !content.trim().is_empty() && ["user", "assistant"].contains(&role) {
            flush(&mut rows, &mut tools);
            rows.push(json!({"kind":"message","id":format!("message:{index}"),"role":role,"text":content,"blocks":if role=="assistant" {markdown(content)} else {json!([])}}));
        }
        for call in message["calls"].as_array().unwrap_or(&empty) {
            let id = text(call, "id");
            let name = text(call, "name");
            let result = results.get(id).copied();
            let approval = if result.is_none() {
                pending.iter().find(|p| {
                    text(p, "type") == "approval"
                        && !used.contains(text(p, "requestId"))
                        && text(&p["payload"], "name") == name
                        && (p["payload"]["arguments"] == redact(call["arguments"].clone())
                            || p["payload"]["arguments"].is_null())
                })
            } else {
                None
            };
            if let Some(p) = approval {
                used.insert(text(p, "requestId").to_owned());
            }
            let state =
                result
                    .map(|r| result_state(text(r, "content")))
                    .unwrap_or(if approval.is_some() {
                        "approval"
                    } else if text(params, "status") == "running" {
                        "running"
                    } else {
                        "interrupted"
                    });
            let output = result.map(|r| text(r, "content")).unwrap_or("");
            let output = serde_json::from_str::<Value>(output)
                .map(|v| pretty(&v))
                .unwrap_or_else(|_| output.to_string());
            tools.push(json!({"id":id,"name":name,"summary":summary(name,&call["arguments"]),"arguments":pretty(&call["arguments"]),"output":output,"state":state,"approval":approval}));
        }
    }
    for p in pending
        .iter()
        .filter(|p| text(p, "type") == "approval" && !used.contains(text(p, "requestId")))
    {
        let payload = &p["payload"];
        let name = text(payload, "name");
        tools.push(json!({"id":text(p,"requestId"),"name":name,"summary":summary(if name.is_empty(){"Agent 请求批准"}else{name},&payload["arguments"]),"arguments":pretty(payload),"output":"","state":"approval","approval":p}));
    }
    flush(&mut rows, &mut tools);
    let streaming = text(params, "streaming");
    if !streaming.trim().is_empty() {
        rows.push(json!({"kind":"message","id":"streaming","role":"assistant","text":streaming,"blocks":markdown(streaming)}));
    }
    json!({"rows":rows})
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn markdown_is_structured_and_does_not_execute_content() {
        let v=markdown("### 资源\n\n- **CPU** `0%`\n\n| PID | 进程 |\n| ---: | --- |\n| 12 | `中文` |\n\n```sh\nprintf '<script>'\n```\n\n[bad](javascript:alert) ![alt](https://invalid/image.png)");
        assert_eq!(v[0]["kind"], "heading");
        assert_eq!(v[1]["kind"], "list");
        assert_eq!(v[2]["kind"], "table");
        assert_eq!(v[2]["alignments"][0], "right");
        assert_eq!(v[3]["kind"], "codeBlock");
        assert_eq!(v[4]["children"][0]["url"], "");
        assert!(!v.to_string().contains("https://invalid"));
    }
    #[test]
    fn empty_assistants_and_tool_results_become_one_correlated_group() {
        let v = render(
            &json!({"status":"completed","messages":[{"role":"user","content":"检查"},{"role":"assistant","calls":[{"id":"a","name":"terminal_execute","arguments":{"command":"uptime"}}]},{"role":"tool","callId":"a","content":"{\"code\":1,\"error\":\"failed\"}"},{"role":"assistant","content":"结果"}]}),
        );
        assert_eq!(v["rows"].as_array().unwrap().len(), 3);
        assert_eq!(v["rows"][1]["tools"][0]["summary"], "$ uptime");
        assert_eq!(v["rows"][1]["tools"][0]["state"], "error");
    }
    #[test]
    fn pending_approval_is_not_duplicated_or_marked_successful() {
        let p = json!({"requestId":"approval-a","type":"approval","payload":{"name":"terminal_execute","arguments":{"command":"uptime"}}});
        let v = render(
            &json!({"status":"running","messages":[{"role":"assistant","calls":[{"id":"a","name":"terminal_execute","arguments":{"command":"uptime"}}]}],"interactions":[p]}),
        );
        assert_eq!(v["rows"][0]["tools"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["tools"][0]["state"], "approval");
        let v = render(
            &json!({"status":"cancelled","messages":[{"role":"assistant","calls":[{"id":"a","name":"tool","arguments":{}}]}]}),
        );
        assert_eq!(v["rows"][0]["tools"][0]["state"], "interrupted");
    }
    #[test]
    fn tight_list_inline_styles_stay_in_one_paragraph() {
        let v = markdown("- 使用率：**0%**，进程 `init`\n  - 子项");
        assert_eq!(v[0]["children"][0]["children"][0]["kind"], "paragraph");
        assert_eq!(v[0]["children"][0]["children"][1]["kind"], "list");
    }
}
