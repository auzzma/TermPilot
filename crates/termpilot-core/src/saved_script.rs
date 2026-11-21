//! Prepare terminal input without changing the user's interactive shell.
use crate::connection::CoreError;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    Insert,
    Run,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Input {
    pub bracketed_input: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plain_input: Option<String>,
}

pub const PASTE_UNAVAILABLE: &str =
    "Enable bracketed paste in the current shell to use this script.";

pub fn plan(body: &str, action: Action) -> Result<Input, CoreError> {
    let normalized = body
        .trim_start_matches('\u{feff}')
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let text = normalized.trim_end_matches('\n');
    if text.trim().is_empty() {
        return Err(CoreError::new(
            "emptyScript",
            "Enter a script to run or insert.",
        ));
    }
    if text
        .chars()
        .any(|c| c.is_control() && c != '\t' && c != '\n')
    {
        return Err(CoreError::new(
            "scriptControls",
            "The script contains terminal control characters.",
        ));
    }

    let submit = if action == Action::Run { "\r" } else { "" };
    // A plain PTY may treat Tab and high-bit bytes as editing keys and truncate
    // long canonical input lines. Leave room for Return within POSIX MAX_CANON.
    let plain_input = (text.len() < 255 && text.bytes().all(|byte| (b' '..=b'~').contains(&byte)))
        .then(|| format!("{text}{submit}"));
    Ok(Input {
        bracketed_input: format!("\x1b[200~{text}\x1b[201~{submit}"),
        plain_input,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_is_insert_followed_by_one_return() {
        for body in [
            "echo 1\necho 2\necho 3",
            "\u{feff}  cd tmp\r\n\texport V='中文'\r\n\r\n",
            "#!/bin/bash\nfor x in 1 2; do\n  echo \"$x\"\ndone\n",
            "Write-Output $PWD",
            "echo \"$value\"",
        ] {
            let insert = plan(body, Action::Insert).unwrap();
            let run = plan(body, Action::Run).unwrap();
            assert_eq!(run.bracketed_input, format!("{}\r", insert.bracketed_input));
            assert_eq!(
                run.plain_input,
                insert.plain_input.map(|text| format!("{text}\r"))
            );
        }
        assert_eq!(
            plan("echo 1\r\necho 2\r\n", Action::Run)
                .unwrap()
                .bracketed_input,
            "\x1b[200~echo 1\necho 2\x1b[201~\r"
        );
    }

    #[test]
    fn plain_terminals_only_receive_one_short_printable_line() {
        for body in ["echo 1\necho 2", "echo\tx", "echo 中文", &"a".repeat(255)] {
            assert!(plan(body, Action::Run).unwrap().plain_input.is_none());
        }
        assert_eq!(
            plan("cd tmp\n", Action::Run)
                .unwrap()
                .plain_input
                .as_deref(),
            Some("cd tmp\r")
        );
    }

    #[test]
    fn invalid_paste_never_produces_terminal_input() {
        for body in [" \t\n", "echo x\0", "echo x\x1b[201~\recho y", "echo x\x03"] {
            for action in [Action::Insert, Action::Run] {
                assert!(plan(body, action).is_err());
            }
        }
    }
}
