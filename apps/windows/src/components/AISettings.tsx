import { invoke } from "@tauri-apps/api/core";
import { useEffect, useRef, useState } from "react";
import { ai, AIValue } from "../ai";
type Spec = [string, string, string, string[]?];
export function AISettings() {
  const [catalog, setCatalog] = useState<AIValue>({});
  const [settings, setSettings] = useState<AIValue>();
  const [tab, setTab] = useState("提供商");
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState(false);
  const [info, setInfo] = useState<AIValue>({});
  const [skills, setSkills] = useState<AIValue[]>([]);
  const [grants, setGrants] = useState<AIValue[]>([]);
  async function run(work: () => Promise<unknown>) {
    setBusy(true);
    setStatus("");
    try {
      await work();
    } catch (e) {
      setStatus(String(e));
    } finally {
      setBusy(false);
    }
  }
  useEffect(() => {
    void run(async () => {
      const c = await ai("settings.get");
      setCatalog(c);
      setSettings(c.settings);
      setInfo(await ai("integration.info"));
      setGrants(await ai<AIValue[]>("grants.list"));
      setSkills(await ai<AIValue[]>("skills.list") ?? []);
    });
  }, []);
  if (!settings)
    return (
      <div className="ai-settings">
        <h2>AI</h2>
        <p>{status || "正在读取配置…"}</p>
      </div>
    );
  function set(key: string, value: unknown) {
    setSettings((s) => ({ ...s, [key]: value }));
  }
  function update(list: string, index: number, value: AIValue) {
    set(
      list,
      settings![list].map((v: AIValue, i: number) => (i === index ? value : v)),
    );
  }
  function remove(list: string, index: number) {
    set(
      list,
      settings![list].filter((_: AIValue, i: number) => i !== index),
    );
  }
  const fields = (
    object: AIValue,
    onChange: (v: AIValue) => void,
    specs: Spec[],
  ) => <Fields object={object} onChange={onChange} specs={specs} />;
  return (
    <div className="ai-settings">
      <h2>AI</h2>
      <nav>
        {["提供商", "Agent", "工具接入", "网络搜索", "安全"].map((t) => (
          <button
            className={tab === t ? "is-active" : ""}
            key={t}
            onClick={() => setTab(t)}
          >
            {t}
          </button>
        ))}
      </nav>
      {tab === "提供商" && (
        <>
          <div className="ai-settings-title">
            <h3>提供商</h3>
            <select
              value=""
              onChange={(e) => {
                const p = catalog.presets.find(
                  (p: AIValue) =>
                    p.id === e.target.value || p.name === e.target.value,
                );
                if (p)
                  set("providers", [
                    ...(settings.providers ?? []),
                    {
                      ...p,
                      id: crypto.randomUUID(),
                      enabled: true,
                      verifyTls: true,
                      parameters: {},
                      headers: {},
                    },
                  ]);
              }}
            >
              <option value="">添加提供商</option>
              {(catalog.presets ?? []).map((p: AIValue) => (
                <option key={p.id ?? p.name} value={p.id ?? p.name}>
                  {p.name}
                </option>
              ))}
            </select>
          </div>
          {(settings.providers ?? []).map((p: AIValue, i: number) => (
            <Provider
              key={p.id}
              value={p}
              onChange={(v) => update("providers", i, v)}
              onDelete={() => remove("providers", i)}
            />
          ))}
        </>
      )}
      {tab === "Agent" && (
        <>
          <p>外部 Agent 使用其已安装的命令行程序和登录账号。</p>
          {(settings.agents ?? []).map((p: AIValue, i: number) => (
            <details className="ai-settings-card" key={p.id}>
              <summary>{p.name || p.kind}</summary>
              {fields(p, (v) => update("agents", i, v), [
                ["name", "名称", "text"],
                [
                  "kind",
                  "适配器",
                  "select",
                  ["codex", "claude", "opencode", "acp"],
                ],
                ["executable", "可执行文件（留空自动检测）", "text"],
                ["cwd", "工作目录", "text"],
                ["model", "模型（留空使用默认）", "text"],
                ["authMode", "认证方式", "select", ["cli", "apiKey"]],
                ["apiKey", "API Key", "password"],
                ["baseUrl", "Base URL", "text"],
                ["configDirectory", "配置目录", "text"],
                ["settingsFile", "Settings 文件", "text"],
                ["endpoint", "ACP 地址", "text"],
              ])}
              <label>
                启动参数（每行一个参数）
                <textarea
                  value={(p.args ?? []).join("\n")}
                  onChange={(e) =>
                    update("agents", i, {
                      ...p,
                      args: e.target.value.split("\n").filter(Boolean),
                    })
                  }
                />
              </label>
              <JsonField
                label="环境变量"
                value={p.env ?? {}}
                onChange={(env) => update("agents", i, { ...p, env })}
              />
              <button
                onClick={() =>
                  void run(async () =>
                    setStatus(JSON.stringify(await ai("agent.probe", p))),
                  )
                }
              >
                检测
              </button>
              <button onClick={() => remove("agents", i)}>删除</button>
            </details>
          ))}
          <select
            value=""
            onChange={(e) =>
              set("agents", [
                ...(settings.agents ?? []),
                {
                  id: crypto.randomUUID(),
                  name: e.target.value,
                  kind: e.target.value,
                },
              ])
            }
          >
            <option value="">添加外部 Agent</option>
            {(catalog.agents ?? [])
              .filter((a: AIValue) => a.available !== false)
              .map((a: AIValue) => (
                <option key={a.kind} value={a.kind}>
                  {a.name}
                </option>
              ))}
          </select>
        </>
      )}
      {tab === "工具接入" && (
        <>
          {fields(settings.toolAccess ?? {}, (v) => set("toolAccess", v), [
            ["mode", "工具接入", "select", ["mcp", "skills-cli"]],
            ["availability", "可用模式", "select", ["temporary", "persistent"]],
            ["idleMinutes", "空闲超时（分钟）", "number"],
            ["activateOnHostOpen", "打开主机时激活窗口", "checkbox"],
          ])}
          {fields(settings, (v) => setSettings(v), [
            ["selectionShortcut", "选中终端内容时显示添加到对话", "checkbox"],
          ])}
          <button
            disabled={busy}
            onClick={() =>
              void run(async () => {
                setInfo(await ai("mcp.enable"));
                setStatus("工具接入已开启");
              })
            }
          >
            开启工具接入
          </button>
          <button
            disabled={busy}
            onClick={() =>
              void run(async () => {
                await ai("mcp.disable");
                setStatus("工具接入已关闭");
              })
            }
          >
            关闭工具接入
          </button>
          <button
            onClick={() =>
              void run(async () => setInfo(await ai("integration.info")))
            }
          >
            刷新接入信息
          </button>
          <IntegrationInfo info={info} />
          <div className="ai-settings-card">
            <h3>用户 Skills</h3>
            <button disabled={busy} onClick={()=>void run(async()=>setSkills(await ai<AIValue[]>("skills.list") ?? []))}>重新加载 Skills</button>
            <button disabled={!info.skillsDirectory} onClick={()=>void run(()=>invoke("local_open",{path:info.skillsDirectory}))}>打开 Skills 文件夹</button>
            <p>已就绪 {skills.length} 个</p>
            {skills.map(skill=><p key={skill.id}>{skill.name ?? skill.id}</p>)}
          </div>
          <h3>快捷消息</h3>
          {(settings.quickMessages ?? []).map((q: AIValue, i: number) => (
            <div className="ai-settings-card" key={q.id}>
              {fields(q, (v) => update("quickMessages", i, v), [
                ["name", "名称", "text"],
                ["slug", "快捷指令", "text"],
                ["content", "内容", "textarea"],
              ])}
              <button onClick={() => remove("quickMessages", i)}>删除</button>
            </div>
          ))}
          <button
            onClick={() =>
              set("quickMessages", [
                ...(settings.quickMessages ?? []),
                { id: crypto.randomUUID(), name: "", slug: "", content: "" },
              ])
            }
          >
            添加快捷消息
          </button>
        </>
      )}
      {tab === "网络搜索" &&
        fields(settings.search ?? {}, (v) => set("search", v), [
          ["enabled", "启用网络搜索", "checkbox"],
          [
            "kind",
            "搜索服务",
            "select",
            ["tavily", "exa", "bocha", "zhipu", "searxng"],
          ],
          ["apiKey", "API Key", "password"],
          ["endpoint", "API 地址", "text"],
          ["maxResults", "最大结果数", "number"],
        ])}
      {tab === "安全" && (
        <>
          {fields(settings, (v) => setSettings(v), [
            ["mode", "权限模式", "select", ["observe", "confirm", "auto"]],
            ["maxIterations", "最大迭代次数", "number"],
            ["commandTimeout", "命令超时（秒）", "number"],
          ])}
          <label>
            命令黑名单（每行一条）
            <textarea
              value={(settings.commandBlacklist ?? []).join("\n")}
              onChange={(e) =>
                set(
                  "commandBlacklist",
                  e.target.value.split("\n").filter(Boolean),
                )
              }
            />
          </label>
          <h3>已记住的授权</h3>
          {grants.map((g) => (
            <div key={g.id} className="ai-settings-card">
              <span>{g.name ?? g.tool ?? g.id}</span>
              <button
                onClick={() =>
                  void run(async () => {
                    await ai("grants.delete", { id: g.id });
                    setGrants(await ai<AIValue[]>("grants.list"));
                  })
                }
              >
                撤销
              </button>
            </div>
          ))}
        </>
      )}
      <p role="status">{status}</p>
      <footer>
        <button
          className="primary"
          disabled={busy}
          onClick={() =>
            void run(async () => {
              await ai("settings.save", { settings });
              setStatus("已保存");
              window.dispatchEvent(new Event("termpilot:ai-settings-changed"));
            })
          }
        >
          保存设置
        </button>
      </footer>
    </div>
  );
}
function Fields({
  object,
  onChange,
  specs,
}: {
  object: AIValue;
  onChange: (v: AIValue) => void;
  specs: Spec[];
}) {
  return (
    <div className="ai-settings-fields">
      {specs.map(([key, label, type, options]) => (
        <label key={key}>
          <span>{label}</span>
          {type === "select" ? (
            <select
              value={object[key] ?? options?.[0] ?? ""}
              onChange={(e) => onChange({ ...object, [key]: e.target.value })}
            >
              {options?.map((o) => (
                <option key={o}>{o}</option>
              ))}
            </select>
          ) : type === "textarea" ? (
            <textarea
              value={object[key] ?? ""}
              onChange={(e) => onChange({ ...object, [key]: e.target.value })}
            />
          ) : type === "checkbox" ? (
            <input
              type="checkbox"
              checked={!!object[key]}
              onChange={(e) => onChange({ ...object, [key]: e.target.checked })}
            />
          ) : (
            <input
              type={type}
              autoComplete={type === "password" ? "off" : undefined}
              value={object[key] ?? ""}
              onChange={(e) =>
                onChange({
                  ...object,
                  [key]:
                    type === "number" ? Number(e.target.value) : e.target.value,
                })
              }
            />
          )}
        </label>
      ))}
    </div>
  );
}
function JsonField({
  label,
  value,
  onChange,
}: {
  label: string;
  value: AIValue;
  onChange: (v: AIValue) => void;
}) {
  const [text, setText] = useState(JSON.stringify(value, null, 2));
  const [error, setError] = useState("");
  return (
    <label>
      {label}
      <textarea
        value={text}
        onChange={(e) => {
          setText(e.target.value);
          try {
            const v = JSON.parse(e.target.value);
            if (!v || Array.isArray(v) || typeof v !== "object") throw Error();
            onChange(v);
            setError("");
          } catch {
            setError("JSON 格式无效，修正后才会更新");
          }
        }}
      />
      {error && <small role="alert">{error}</small>}
    </label>
  );
}
function IntegrationInfo({ info }: { info: AIValue }) {
  const [client, setClient] = useState("codex");
  const [copied, setCopied] = useState(false);
  const text = info.clients?.[client] ?? "";
  return (
    <div className="ai-settings-card">
      <p>{info.status?.enabled ? "工具接入已开启" : "工具接入未开启"}</p>
      <select value={client} onChange={(e) => setClient(e.target.value)}>
        {["codex", "claude", "cursor", "grok"].map((c) => (
          <option key={c}>{c}</option>
        ))}
      </select>
      <button
        disabled={!text}
        onClick={() =>
          void navigator.clipboard.writeText(text).then(() => setCopied(true))
        }
      >
        {copied ? "已复制" : "复制接入配置"}
      </button>
      <pre>{text}</pre>
      <p>Skills 目录：{info.skillsDirectory}</p>
    </div>
  );
}
function Provider({
  value: p,
  onChange,
  onDelete,
}: {
  value: AIValue;
  onChange: (v: AIValue) => void;
  onDelete: () => void;
}) {
  const [models, setModels] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const request = useRef(0);
  const current = useRef(p);
  current.current = p;
  const discoveryKey = JSON.stringify([
    p.protocol,
    p.baseUrl,
    p.apiKey,
    p.proxy,
    p.verifyTls,
    p.headers,
  ]);
  async function discover() {
    const id = ++request.current;
    setBusy(true);
    setError("");
    try {
      const r = await ai("provider.models", { provider: current.current });
      if (id === request.current) setModels(r.modelIds ?? []);
    } catch (e) {
      if (id === request.current) setError(String(e));
    } finally {
      if (id === request.current) setBusy(false);
    }
  }
  useEffect(() => {
    request.current++;
    setModels([]);
    setError("");
    setBusy(false);
    if (!p.baseUrl || (!p.apiKey && p.kind !== "ollama")) return;
    const timer = setTimeout(() => void discover(), 800);
    return () => {
      clearTimeout(timer);
      request.current++;
    };
  }, [discoveryKey]);
  return (
    <details className="ai-settings-card" open={!p.apiKey}>
      <summary>
        {p.name || "提供商"} · {p.model || "选择模型"}
      </summary>
      <Fields
        object={p}
        onChange={onChange}
        specs={[
          ["name", "显示名称", "text"],
          [
            "protocol",
            "协议风格",
            "select",
            ["chat", "responses", "anthropic", "google"],
          ],
          ["apiKey", "API Key", "password"],
          ["baseUrl", "Base URL", "text"],
        ]}
      />
      <label className="ai-provider-model">
        <span>默认模型</span>
        <input
          list={`models-${p.id}`}
          value={p.model ?? ""}
          placeholder="自动获取后选择，也可手动输入"
          onChange={(e) => onChange({ ...p, model: e.target.value })}
        />
        <datalist id={`models-${p.id}`}>
          {models.map((m) => (
            <option key={m}>{m}</option>
          ))}
        </datalist>
        <button disabled={busy} onClick={() => void discover()}>
          {busy ? "正在获取…" : "刷新模型"}
        </button>
      </label>
      {models.length > 0 && (
        <select
          aria-label="获取的模型"
          value={p.model ?? ""}
          onChange={(e) => onChange({ ...p, model: e.target.value })}
        >
          <option value="">从 {models.length} 个模型中选择</option>
          {models.map((m) => (
            <option key={m}>{m}</option>
          ))}
        </select>
      )}
      {error && <p role="alert">{error}</p>}
      <Fields
        object={p}
        onChange={onChange}
        specs={[
          ["contextWindow", "上下文窗口（可留空）", "number"],
          ["proxy", "代理地址", "text"],
          ["verifyTls", "验证 TLS 证书", "checkbox"],
          ["enabled", "启用", "checkbox"],
        ]}
      />
      <details>
        <summary>高级参数</summary>
        <Fields
          object={p.parameters ?? {}}
          onChange={(v) => onChange({ ...p, parameters: v })}
          specs={[
            "max_tokens",
            "temperature",
            "top_p",
            "frequency_penalty",
            "presence_penalty",
          ].map((k) => [k, k, "number"])}
        />
        <JsonField
          label="自定义请求头"
          value={p.headers ?? {}}
          onChange={(headers) => onChange({ ...p, headers })}
        />
      </details>
      <button onClick={onDelete}>删除提供商</button>
    </details>
  );
}
