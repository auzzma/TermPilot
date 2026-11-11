# 来源与许可证

- macOS 功能基线为 Swift 版 0.1.7 build 12 的一次性源码快照（2026-10-02）。本仓库中的副本独立维护，迁移审计记录不属于构建输入。
- 新项目不从两个旧项目导入模块、读取资源、链接二进制或启动其可执行文件。第三方开源依赖仍通过各自包管理器和锁文件获取。
- Rust 核心、原生客户端桥接及项目脚本按根目录 GPL-3.0-or-later 许可证提供。包含屏幕共享派生实现的 `engines/rust` 连接引擎按 AGPL-3.0-or-later 提供。
- 屏幕共享协议来源于 [iShareScreen](https://github.com/renegadelink/iShareScreen)，固定版本见 `engines/rust/UPSTREAM`，AGPL-3.0-or-later 许可证见 `engines/rust/LICENSE`。当前 Rust 派生实现及 macOS 媒体桥接包含在本项目对应源码包中。
- Rust、SwiftTerm、GRDB 等实际链接依赖保留各自许可证，分发包中的 `Licenses` 目录包含声明。历史 Node/Python 引擎不属于当前构建输入；应用不打包或启动这些运行时。
- 源码包由 `scripts/package-source.py` 创建，排除机器缓存、构建产物和个人数据。
- AI 工具名称、说明、参数合同及策略元数据改编自 Netcatty（binaricat，GPL-3.0-or-later），固定提交 `b2ed83ae5108b479d1b509aba208a233e5240a0f` 的 `infrastructure/ai/harness/generated/{cattyToolSpecs,globalAgentToolSpecs}.json`。修改包括产品名替换、JSON Schema 转换和原生适配能力筛选，保存在 `crates/termpilot-ai/src/catalog.json`；Rust 实现不运行上游 JavaScript。原始项目与许可证：https://github.com/binaricat/Netcatty/tree/b2ed83ae5108b479d1b509aba208a233e5240a0f。
- AI 设置分类、表单字段、默认值与命令黑名单依据 Netcatty 1.1.73 界面和应用资源核对；黑名单规则适配在 `crates/termpilot-ai/src/settings.rs`，未复制用户凭证。
- MCP 渐进工具集分组参考同一 Netcatty 提交的 `electron/mcp/progressiveMcpTools.cjs`，本项目数据文件为 `crates/termpilot-ai/src/mcp_toolsets.json`。JavaScript 自动化的 `nct` API 依据上游公开行为合同独立实现；执行环境为原生嵌入式 QuickJS，不包含 Node.js/Python。
- AI 原生脚本依赖 `rquickjs`/`rquickjs-sys`（MIT，https://github.com/DelSkayn/rquickjs）及其随附 QuickJS 引擎许可证；YAML 元数据依赖 `serde_yaml_ng`，输出触发器依赖 `regex`。锁定版本及全部许可证由 `Cargo.lock` 和发行包 `Licenses/dependencies.json` 记录，构建时收集源码中的许可证文件。

## RDP

The RDP worker uses IronRDP (MIT OR Apache-2.0), pinned to `38b074e4befeed6dd25a67decf3558bb9e7762f9`. The independent client facade and its license texts are in `vendor/ironrdp-client`; local changes are described in `TERMPILOT-PATCHES.json`. The distribution includes corresponding source and dependency license inventories for both Rust workspaces.

## Windows media conversion utility

Apple high-performance video/audio on Windows uses `termpilot-media`, an independently replaceable MIT-licensed stdin/stdout codec utility (source in `engines/media-codec`). It dynamically loads libde265 1.1.3 (LGPL-3.0-or-later) and Fraunhofer FDK AAC 2.0.3 (its own license). The utility does not implement the Apple protocol. Full library sources, build scripts and original notices are included in CorrespondingSource and Licenses/Media; neither library requires Node.js or Python at runtime. FDK AAC's license does not grant patent rights; see its complete NOTICE. The supplied utility and codec DLLs can be rebuilt and replaced together in app/engine.

## Mobile clients

The iPhone/iPad and Android applications run these Rust libraries in process. SwiftTerm provides the iOS terminal (MIT); Android uses the shared vt100 parser and an independent native Canvas frontend. UIKit/Metal/VideoToolbox/AudioToolbox and Android Compose/OpenGL ES/AudioTrack are platform adapters, not separate protocol engines. AndroidX, Kotlin and kotlinx dependencies retain Apache-2.0 notices; the exact Maven inventory accompanies the Android packages.

Mobile-only compatibility patches for picky, sspi and ironrdp-tls are included under vendor with their upstream license files and patch explanations. Mobile RDP validates TLS against the Mozilla root set supplied by webpki-roots and supports explicit per-certificate approval. Desktop certificate defaults are unchanged.

On Android the MIT media adapter links replaceable shared libde265 and FDK AAC libraries. Their complete source, build instructions and notices are included in the source distribution. Application source and build inputs permit rebuilding and replacing the APK with a developer's own signing key; the test signing identity is not a production key. iOS uses Apple's system codecs. No store submission or codec patent license is included in this internal testing deliverable.
