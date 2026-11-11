//! Native test peer for protocol acceptance. Never packaged with TermPilot.
use serde_json::{json, Value};
use std::io::{BufRead, Write};
fn send(v: Value) {
    println!("{v}");
    std::io::stdout().flush().unwrap();
}
fn main() {
    if std::env::args().any(|a| a == "--version") {
        println!("TermPilot protocol fixture 1");
        return;
    }
    let kind = std::env::var("TERMPILOT_FIXTURE_AGENT").unwrap();
    for line in std::io::stdin().lock().lines() {
        let v: Value = serde_json::from_str(&line.unwrap()).unwrap();
        match kind.as_str() {
            "codex" => match v["method"].as_str().unwrap_or("") {
                "initialize" => send(json!({"id":v["id"],"result":{}})),
                "initialized" => {}
                "thread/start" | "thread/resume" => {
                    assert_eq!(v["params"]["approvalPolicy"], "on-request");
                    assert!(v["params"]["config"]["mcp_servers"]["TermPilot"]["url"]
                        .as_str()
                        .unwrap()
                        .starts_with("http://127.0.0.1:"));
                    send(json!({"id":v["id"],"result":{"thread":{"id":"fixture-codex"}}}));
                }
                "turn/start" => {
                    // Request arrives before the turn/start acknowledgment.
                    send(
                        json!({"id":"permission","method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}},"threadId":"fixture-codex","turnId":"turn"}}),
                    );
                    send(json!({"id":v["id"],"result":{"turn":{"id":"turn"}}}));
                }
                "" if v["id"] == "permission" => {
                    assert_eq!(v["result"]["permissions"]["network"]["enabled"], true);
                    assert_eq!(v["result"]["scope"], "turn");
                    send(
                        json!({"id":"question","method":"item/tool/requestUserInput","params":{"questions":[{"id":"first","question":"First?"},{"id":"second","question":"Second?"}]}}),
                    );
                }
                "" if v["id"] == "question" => {
                    assert_eq!(
                        v["result"]["answers"]["first"]["answers"][0],
                        "first-answer"
                    );
                    assert_eq!(
                        v["result"]["answers"]["second"]["answers"][0],
                        "second-answer"
                    );
                    send(
                        json!({"method":"item/agentMessage/delta","params":{"delta":"Codex 协议通过"}}),
                    );
                    send(
                        json!({"method":"turn/completed","params":{"turn":{"status":"completed"}}}),
                    );
                }
                other => panic!("unexpected fixture method {other}"),
            },
            "acp" => match v["method"].as_str().unwrap_or("") {
                "initialize" => {
                    assert_eq!(v["jsonrpc"], "2.0");
                    send(
                        json!({"jsonrpc":"2.0","id":v["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true}}}}),
                    );
                }
                "session/new" | "session/load" => {
                    assert_eq!(v["params"]["mcpServers"][0]["args"][0], "ai-mcp");
                    send(
                        json!({"jsonrpc":"2.0","id":v["id"],"result":{"sessionId":"fixture-acp"}}),
                    );
                }
                "session/prompt" => {
                    send(
                        json!({"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"fixture-acp","options":[{"kind":"allow_once","optionId":"once"},{"kind":"reject_once","optionId":"reject"}],"toolCall":{"title":"Fixture"}}}),
                    );
                }
                "" if v["id"] == "permission" => {
                    assert_eq!(v["result"]["outcome"]["optionId"], "once");
                    send(
                        json!({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture-acp","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ACP 协议通过"}}}}),
                    );
                    send(json!({"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}));
                }
                other => panic!("unexpected ACP method {other}"),
            },
            "claude" => match v["type"].as_str().unwrap_or("") {
                "control_request" => {
                    assert_eq!(v["request"]["subtype"], "initialize");
                    send(
                        json!({"type":"control_response","response":{"request_id":"initialize","subtype":"success","response":{}}}),
                    );
                }
                "user" => {
                    send(json!({"type":"system","subtype":"init","session_id":"fixture-claude"}));
                    send(
                        json!({"type":"control_request","request_id":"question","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"First?"},{"question":"Second?"}]}}}),
                    );
                }
                "control_response" => {
                    assert_eq!(v["response"]["subtype"], "success");
                    assert_eq!(v["response"]["response"]["behavior"], "allow");
                    assert_eq!(
                        v["response"]["response"]["updatedInput"]["answers"]["First?"],
                        "first-answer"
                    );
                    assert_eq!(
                        v["response"]["response"]["updatedInput"]["answers"]["Second?"],
                        "second-answer"
                    );
                    send(
                        json!({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Claude 协议通过"}}}),
                    );
                    send(
                        json!({"type":"assistant","message":{"content":[{"type":"text","text":"Claude 协议通过"}]}}),
                    );
                    send(
                        json!({"type":"result","subtype":"success","is_error":false,"result":"Claude 协议通过","usage":{"input_tokens":1}}),
                    );
                }
                other => panic!("unexpected Claude message {other}"),
            },
            _ => panic!("unknown fixture"),
        }
    }
}
