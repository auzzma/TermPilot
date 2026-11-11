use crate::connection::CoreError;
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};
#[derive(Default)]
struct Replies {
    bytes: Vec<u8>,
}
impl vt100::Callbacks for Replies {
    fn unhandled_csi(
        &mut self,
        screen: &mut vt100::Screen,
        i1: Option<u8>,
        _: Option<u8>,
        params: &[&[u16]],
        c: char,
    ) {
        let first = params.first().and_then(|p| p.first()).copied().unwrap_or(0);
        let response = match (i1, c, first) {
            (None, 'n', 5) => "\x1b[0n".to_owned(),
            (None, 'n', 6) => {
                let (r, c) = screen.cursor_position();
                format!("\x1b[{};{}R", r + 1, c + 1)
            }
            (None, 'c', 0) => "\x1b[?1;2c".to_owned(),
            (Some(b'>'), 'c', 0) => "\x1b[>0;1;0c".to_owned(),
            _ => String::new(),
        };
        if self.bytes.len() + response.len() < 65536 {
            self.bytes.extend(response.bytes());
        }
    }
}
struct Terminal {
    parser: vt100::Parser<Replies>,
    revision: u64,
}
static TERMINALS: OnceLock<Mutex<HashMap<String, Terminal>>> = OnceLock::new();
fn size(v: &Value, key: &str, default: u64, max: u64) -> u16 {
    v[key].as_u64().unwrap_or(default).clamp(1, max) as u16
}
fn color(c: vt100::Color) -> Value {
    match c {
        vt100::Color::Default => Value::Null,
        vt100::Color::Idx(n) => json!(n),
        vt100::Color::Rgb(r, g, b) => json!([r, g, b]),
    }
}
pub fn dispatch(request: &Value) -> Result<Value, CoreError> {
    let mut all = TERMINALS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .map_err(|_| CoreError::new("terminalError", "Terminal state is unavailable."))?;
    let method = request["method"].as_str().unwrap_or("");
    if method == "terminal.create" {
        if all.len() >= 64 {
            return Err(CoreError::new(
                "sessionLimit",
                "Close an existing terminal before opening another.",
            ));
        }
        let id = uuid::Uuid::new_v4().to_string();
        all.insert(
            id.clone(),
            Terminal {
                parser: vt100::Parser::new_with_callbacks(
                    size(request, "rows", 24, 200),
                    size(request, "columns", 80, 400),
                    10_000,
                    Replies::default(),
                ),
                revision: 1,
            },
        );
        return Ok(json!({"id":id}));
    }
    let id = request["id"].as_str().unwrap_or("");
    if method == "terminal.close" {
        all.remove(id);
        return Ok(json!({"closed":true}));
    }
    let terminal = all.get_mut(id).ok_or(CoreError::new(
        "unknownTerminal",
        "Terminal session is closed.",
    ))?;
    match method {
        "terminal.feed" => {
            let data = B64
                .decode(request["data"].as_str().unwrap_or(""))
                .map_err(|_| CoreError::new("invalidData", "Invalid terminal bytes."))?;
            terminal.parser.process(&data);
            terminal.revision += 1;
            Ok(
                json!({"revision":terminal.revision,"reply":B64.encode(std::mem::take(&mut terminal.parser.callbacks_mut().bytes))}),
            )
        }
        "terminal.resize" => {
            terminal.parser.screen_mut().set_size(
                size(request, "rows", 24, 200),
                size(request, "columns", 80, 400),
            );
            terminal.revision += 1;
            Ok(json!({"resized":true}))
        }
        "terminal.scroll" => {
            let s = terminal.parser.screen_mut();
            let offset =
                (s.scrollback() as i64 + request["lines"].as_i64().unwrap_or(0)).max(0) as usize;
            s.set_scrollback(offset);
            terminal.revision += 1;
            Ok(json!({"offset":s.scrollback()}))
        }
        "terminal.text" => {
            let screen = terminal.parser.screen();
            Ok(json!({"text":screen.contents()}))
        }
        "terminal.context" => {
            for key in ["maxLines", "startLine"] {
                if request.get(key).is_some_and(|v| v.as_u64().is_none()) {
                    return Err(CoreError::new(
                        "invalidRange",
                        "Terminal line bounds must be non-negative integers.",
                    ));
                }
            }
            let range = request["range"].as_str().unwrap_or("viewport");
            if !["viewport", "head", "tail", "lines"].contains(&range) {
                return Err(CoreError::new("invalidRange", "Unknown terminal range."));
            }
            let maximum = request["maxLines"].as_u64().unwrap_or(80).clamp(1, 300) as usize;
            let start_line = request["startLine"].as_u64().unwrap_or(0) as usize;
            let screen = terminal.parser.screen_mut();
            let saved = screen.scrollback();
            let (rows, cols) = screen.size();
            screen.set_scrollback(usize::MAX);
            let history = screen.scrollback();
            let total = history + usize::from(rows);
            let start = match range {
                "viewport" => history - saved,
                "head" => 0,
                "tail" => total.saturating_sub(maximum),
                _ => start_line.min(total),
            };
            let end = (start
                + if range == "viewport" {
                    maximum.min(usize::from(rows))
                } else {
                    maximum
                })
            .min(total);
            let mut lines = vec![];
            for index in start..end {
                screen.set_scrollback(history.saturating_sub(index));
                let row = index.saturating_sub(history);
                lines.push(screen.rows(0, cols).nth(row).unwrap_or_default());
            }
            screen.set_scrollback(saved);
            Ok(
                json!({"text":lines.join("\n"),"range":range,"startLine":start,"nextLine":end,"totalLines":total,"rows":rows,"cols":cols,"currentRow":screen.cursor_position().0,"truncated":end<total,"retention":"current scrollback buffer"}),
            )
        }
        "terminal.snapshot" => {
            if request["revision"].as_u64() == Some(terminal.revision) {
                return Ok(json!({"revision":terminal.revision,"changed":false}));
            }
            let screen = terminal.parser.screen();
            let (rows, columns) = screen.size();
            let mut cells = Vec::new();
            for row in 0..rows {
                for col in 0..columns {
                    if let Some(cell) = screen.cell(row, col) {
                        if cell.is_wide_continuation() {
                            continue;
                        }
                        if !cell.has_contents()
                            && cell.bgcolor() == vt100::Color::Default
                            && !cell.inverse()
                        {
                            continue;
                        }
                        cells.push(json!({"row":row,"column":col,"text":cell.contents(),"width":if cell.is_wide(){2}else{1},"fg":color(cell.fgcolor()),"bg":color(cell.bgcolor()),"bold":cell.bold(),"italic":cell.italic(),"underline":cell.underline(),"inverse":cell.inverse()}));
                    }
                }
            }
            let (r, c) = screen.cursor_position();
            Ok(
                json!({"revision":terminal.revision,"changed":true,"rows":rows,"columns":columns,"cells":cells,"cursorRow":r,"cursorColumn":c,"hideCursor":screen.hide_cursor(),"alternateScreen":screen.alternate_screen(),"applicationCursor":screen.application_cursor(),"bracketedPaste":screen.bracketed_paste(),"scrollback":screen.scrollback(),"mouseMode":format!("{:?}",screen.mouse_protocol_mode()),"mouseEncoding":format!("{:?}",screen.mouse_protocol_encoding())}),
            )
        }
        _ => Err(CoreError::new(
            "unknownMethod",
            "Unknown terminal operation.",
        )),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn context_ranges_preserve_user_scrollback_and_unicode() {
        let id = dispatch(&json!({"method":"terminal.create","rows":3,"columns":40})).unwrap()
            ["id"]
            .clone();
        for i in 0..12 {
            dispatch(
                &json!({"method":"terminal.feed","id":id,"data":B64.encode(format!("行{i}\r\n"))}),
            )
            .unwrap();
        }
        dispatch(&json!({"method":"terminal.scroll","id":id,"lines":4})).unwrap();
        let before = dispatch(&json!({"method":"terminal.text","id":id})).unwrap();
        let head =
            dispatch(&json!({"method":"terminal.context","id":id,"range":"head","maxLines":2}))
                .unwrap();
        assert_eq!(head["text"], "行0\n行1");
        let middle=dispatch(&json!({"method":"terminal.context","id":id,"range":"lines","startLine":5,"maxLines":2})).unwrap();
        assert_eq!(middle["text"], "行5\n行6");
        assert_eq!(middle["nextLine"], 7);
        assert!(middle["truncated"].as_bool().unwrap());
        let tail =
            dispatch(&json!({"method":"terminal.context","id":id,"range":"tail","maxLines":3}))
                .unwrap();
        assert!(tail["text"].as_str().unwrap().contains("行11"));
        assert_eq!(
            before,
            dispatch(&json!({"method":"terminal.text","id":id})).unwrap()
        );
        assert!(dispatch(&json!({"method":"terminal.context","id":id,"startLine":-1})).is_err());
        dispatch(&json!({"method":"terminal.close","id":id})).unwrap();
    }
    #[test]
    fn unicode_alternate_screen_and_bracketed_paste() {
        let id = dispatch(&json!({"method":"terminal.create","rows":4,"columns":20})).unwrap()
            ["id"]
            .clone();
        let feed = |text: &str| {
            dispatch(&json!({"method":"terminal.feed","id":id,"data":B64.encode(text)})).unwrap()
        };
        feed("中文\x1b[31mRED\x1b[0m\x1b[?2004h");
        let snap = dispatch(&json!({"method":"terminal.snapshot","id":id})).unwrap();
        assert_eq!(snap["cells"][0]["width"], 2);
        assert_eq!(snap["bracketedPaste"], true);
        feed("\x1b[?1049hOTHER\x1b[?1049l");
        assert!(
            dispatch(&json!({"method":"terminal.text","id":id})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("中文RED")
        );
        dispatch(&json!({"method":"terminal.close","id":id})).unwrap();
    }
}
