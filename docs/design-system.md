# TermPilot Design System

## 1. 原则 (Principles)
- **Source of Truth**: Swift 原生端为跨平台 UI/UX 对齐的唯一基准。
- **全面浅色化**: 避免使用大面积硬编码深色（如 `#0d1117`），确保在浅色模式下界面的清晰和优雅。
- **语义化令牌 (Semantic Tokens)**: 避免使用透明度叠加（如 8% 白色）来模拟卡片，使用显式的背景色与边框区分层级。

## 2. 形状与圆角 (Shape & Border Radius)
- **通用控件 (Buttons, Inputs, Dialogs)**: `6px` 圆角。
- **终端 Tab**: 顶部圆角，底部直角，或者统一使用系统默认 tab 样式。

## 3. 色彩令牌 (Color Tokens)
| Token 名称 | 描述 | Swift 映射 | Tauri (CSS 变量) |
| --- | --- | --- | --- |
| `--bg-window` | 主窗口背景，浅色下为白色或浅灰，深色下为深色 | `Color(nsColor: .windowBackgroundColor)` | `var(--bg-window)` |
| `--bg-elevated` | 悬浮层/卡片背景（如侧边栏项目、弹窗） | `Color(nsColor: .controlBackgroundColor)` | `var(--bg-elevated)` |
| `--bg-terminal` | 终端工作区背景（浅色 GitHub 风格 `#f6f8fa`，深色 `#0d1117` 等） | `Theme/Color` | `var(--bg-terminal)` |
| `--text-primary` | 主要文本颜色 | `Color.primary` | `var(--text-primary)` |
| `--text-secondary`| 次要文本颜色 | `Color.secondary` | `var(--text-secondary)` |
| `--border-subtle` | 细微边框颜色，用于卡片分割 | `Color.secondary.opacity(0.2)` 或显式颜色 | `var(--border-subtle)` |

## 4. 动效 (Motion)
- 状态过渡（Hover/Active）：`0.15s ease-out`。
- 弹窗（Sheet）：使用 macOS 原生下滑动画（或 Tauri 模拟的 slideDownSheet）。

## 5. 图标 (Iconography)
- 线宽 (Stroke Width): `1.5px` 或 `2px`。
- 风格: SF Symbols 风格，Tauri 端采用 Lucide Icons 对齐。
