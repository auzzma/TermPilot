use ironrdp_client::rdp::RdpInputEvent;
use ironrdp_input::{Database, MouseButton, MousePosition, Operation, Scancode, WheelRotations};
use serde_json::Value;

#[derive(Default)]
pub struct Input {
    database: Database,
}
impl Input {
    pub fn command(&mut self, v: &Value) -> Option<RdpInputEvent> {
        let mut operations = Vec::new();
        match v["kind"].as_str()? {
            "release" => return Some(RdpInputEvent::FastPath(self.database.release_all())),
            "pointer" => {
                operations.push(Operation::MouseMove(MousePosition {
                    x: v["x"].as_u64()?.min(65535) as u16,
                    y: v["y"].as_u64()?.min(65535) as u16,
                }));
                let buttons = v["buttons"].as_u64().unwrap_or(0);
                for (bit, button) in [
                    (1, MouseButton::Left),
                    (2, MouseButton::Right),
                    (4, MouseButton::Middle),
                ] {
                    operations.push(if buttons & bit != 0 {
                        Operation::MouseButtonPressed(button)
                    } else {
                        Operation::MouseButtonReleased(button)
                    });
                }
            }
            "scroll" => operations.push(Operation::WheelRotations(WheelRotations {
                is_vertical: true,
                rotation_units: (-v["dy"].as_f64().unwrap_or(0.0).signum() * 120.0) as i16,
            })),
            "text" => {
                let mut previous_cr = false;
                for c in v["text"].as_str()?.chars().take(32768) {
                    // IMEs can commit Enter/Tab as text. Windows applications
                    // need physical key events for these actions, not VK_PACKET.
                    if c == '\n' && previous_cr {
                        previous_cr = false;
                        continue;
                    }
                    previous_cr = c == '\r';
                    let code = match c {
                        '\r' | '\n' => Some(0x1c),
                        '\t' => Some(0x0f),
                        '\u{8}' => Some(0x0e),
                        '\u{1b}' => Some(0x01),
                        _ => None,
                    };
                    if let Some(code) = code {
                        operations.push(Operation::KeyPressed(Scancode::from_u16(code)));
                        operations.push(Operation::KeyReleased(Scancode::from_u16(code)));
                    } else {
                        operations.push(Operation::UnicodeKeyPressed(c));
                        operations.push(Operation::UnicodeKeyReleased(c));
                    }
                }
            }
            "key" => {
                let key = v["key"].as_u64()? as u32;
                let down = v["down"].as_bool().unwrap_or(false);
                if let Some(code) = scancode(key) {
                    operations.push(if down {
                        Operation::KeyPressed(code.into())
                    } else {
                        Operation::KeyReleased(code.into())
                    });
                } else if let Some(c) = char::from_u32(if key & 0xff000000 == 0x01000000 {
                    key & 0xffffff
                } else {
                    key
                }) {
                    operations.push(if down {
                        Operation::UnicodeKeyPressed(c)
                    } else {
                        Operation::UnicodeKeyReleased(c)
                    });
                }
            }
            "secureAttention" => {
                let codes = [
                    Scancode::from_u16(0x1d),
                    Scancode::from_u16(0x38),
                    Scancode::from_u16(0xe053),
                ];
                for c in codes {
                    operations.push(Operation::KeyPressed(c));
                }
                for c in codes.into_iter().rev() {
                    operations.push(Operation::KeyReleased(c));
                }
            }
            "resize" => {
                return Some(RdpInputEvent::Resize {
                    width: v["width"].as_u64()?.clamp(320, 3840) as u16,
                    height: v["height"].as_u64()?.clamp(200, 2160) as u16,
                    scale_factor: v["scale"].as_u64().unwrap_or(100).clamp(100, 500) as u32,
                    physical_size: None,
                });
            }
            _ => return None,
        }
        Some(RdpInputEvent::FastPath(self.database.apply(operations)))
    }
}
fn scancode(key: u32) -> Option<u16> {
    let key = if (65..=90).contains(&key) {
        key + 32
    } else {
        key
    };
    let code = match key {
        0xff08 => 0x0e,
        0xff09 => 0x0f,
        0xff0d => 0x1c,
        0xff1b => 1,
        0xffff => 0xe053,
        0xff50 => 0xe047,
        0xff57 => 0xe04f,
        0xff55 => 0xe049,
        0xff56 => 0xe051,
        0xff51 => 0xe04b,
        0xff52 => 0xe048,
        0xff53 => 0xe04d,
        0xff54 => 0xe050,
        0xff63 => 0xe052,
        0xffe1 => 0x2a,
        0xffe2 => 0x36,
        0xffe3 => 0x1d,
        0xffe4 => 0xe01d,
        0xffe9 => 0x38,
        0xffea => 0xe038,
        0xffeb => 0xe05b,
        0xffec => 0xe05c,
        0xffe5 => 0x3a,
        0xffbe..=0xffc7 => (key - 0xffbe + 0x3b) as u16,
        0xffc8 => 0x57,
        0xffc9 => 0x58,
        32 => 0x39,
        49..=57 => (key - 49 + 2) as u16,
        48 => 0x0b,
        97 => 0x1e,
        98 => 0x30,
        99 => 0x2e,
        100 => 0x20,
        101 => 0x12,
        102 => 0x21,
        103 => 0x22,
        104 => 0x23,
        105 => 0x17,
        106 => 0x24,
        107 => 0x25,
        108 => 0x26,
        109 => 0x32,
        110 => 0x31,
        111 => 0x18,
        112 => 0x19,
        113 => 0x10,
        114 => 0x13,
        115 => 0x1f,
        116 => 0x14,
        117 => 0x16,
        118 => 0x2f,
        119 => 0x11,
        120 => 0x2d,
        121 => 0x15,
        122 => 0x2c,
        45 | 95 => 0x0c,
        61 | 43 => 0x0d,
        91 | 123 => 0x1a,
        93 | 125 => 0x1b,
        92 | 124 => 0x2b,
        59 | 58 => 0x27,
        39 | 34 => 0x28,
        96 | 126 => 0x29,
        44 | 60 => 0x33,
        46 | 62 => 0x34,
        47 | 63 => 0x35,
        _ => return None,
    };
    Some(code)
}
#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp_pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
    use serde_json::json;

    #[test]
    fn committed_text_uses_real_keys_for_enter_tab_and_backspace() {
        let mut input = Input::default();
        let Some(RdpInputEvent::FastPath(events)) =
            input.command(&json!({"kind":"text","text":"a\r\n\t\u{8}中"}))
        else {
            panic!("Expected keyboard events")
        };
        assert_eq!(
            events.as_slice(),
            &[
                FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::empty(), 'a' as u16),
                FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::RELEASE, 'a' as u16),
                FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), 0x1c),
                FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE, 0x1c),
                FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), 0x0f),
                FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE, 0x0f),
                FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), 0x0e),
                FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE, 0x0e),
                FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::empty(), '中' as u16),
                FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::RELEASE, '中' as u16),
            ]
        );
        let Some(RdpInputEvent::FastPath(released)) = input.command(&json!({"kind":"release"}))
        else {
            panic!("Expected release")
        };
        assert!(released.is_empty());
    }

    #[test]
    fn unicode_text_preserves_case_symbols_and_surrogate_pairs() {
        let mut input = Input::default();
        let Some(RdpInputEvent::FastPath(events)) =
            input.command(&json!({"kind":"text","text":"Aa!中😀"}))
        else {
            panic!("Expected keyboard events")
        };
        let pressed: Vec<_> = events
            .iter()
            .filter_map(|e| match e {
                FastPathInputEvent::UnicodeKeyboardEvent(flags, code) if flags.is_empty() => {
                    Some(*code)
                }
                _ => None,
            })
            .collect();
        assert_eq!(pressed, "Aa!中😀".encode_utf16().collect::<Vec<_>>());
        assert_eq!(events.len(), pressed.len() * 2);
    }
    #[test]
    fn release_balances_held_keys() {
        let mut input = Input::default();
        input.command(&json!({"kind":"key","key":0xffe3,"down":true}));
        input.command(&json!({"kind":"key","key":99,"down":true}));
        if let Some(RdpInputEvent::FastPath(events)) = input.command(&json!({"kind":"release"})) {
            assert_eq!(events.len(), 2);
        } else {
            panic!();
        }
        if let Some(RdpInputEvent::FastPath(events)) = input.command(&json!({"kind":"release"})) {
            assert!(events.is_empty());
        }
    }
}
