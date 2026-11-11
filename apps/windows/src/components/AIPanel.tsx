import { useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { DeferredWrite } from "../deferredWrite";
import { listen } from "@tauri-apps/api/event";
import { open, save } from "@tauri-apps/plugin-dialog";
import { invoke } from "@tauri-apps/api/core";
import {
  Sparkles,
  History,
  SquarePen,
  Settings,
  ArrowUp,
  Square,
  Paperclip,
  ChevronDown,
} from "lucide-react";
import { ai, AIValue, aiScope, aiInteractions, aiSelectionDrafts, context, terminalSelections } from "../ai";
import { useAppStore } from "../store";
import { Markdown } from "./AIContent";
import { AIModelPicker } from "./AIModelPicker";
import { ThemedSelect } from "./ThemedSelect";
export function AIPanel({
  sessionId,
  label,
}: {
  sessionId: string;
  label: string;
}) {
  const scope = aiScope(sessionId);
  const [settings, setSettings] = useState<AIValue>({});
  const [conversation, setConversation] = useState<AIValue>({});
  const [history, setHistory] = useState<AIValue[]>([]);
  const [draft, setDraft] = useState("");
  const [agent, setAgent] = useState("");
  const [model, setModel] = useState("");
  const [agentCatalog,setAgentCatalog] = useState<AIValue[]>([]);
  const [stream, setStream] = useState("");
  const [pending, setPending] = useState<AIValue[]>([]);
  const [rows, setRows] = useState<AIValue[]>([]);
  const [error, setError] = useState("");
  const [showHistory, setShowHistory] = useState(false);
  const [files, setFiles] = useState<string[]>([]);
  const [skills, setSkills] = useState<AIValue[]>([]);
  const [selectedSkills, setSelectedSkills] = useState<string[]>([]);
  const composer = useRef<HTMLFormElement>(null);
  const [draftWriter] = useState(() => new DeferredWrite<{conversationId:string; draft:string}>(
    async value => { await ai("conversation.draft", value); },
    error => { if (error) setError(String(error)); }, 400,
  ));
  const [latest, setLatest] = useState(false);
  const scroll = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const current = useRef(conversation);
  current.current = conversation;
  useEffect(() => {
    const receive = () => {
      const text = aiSelectionDrafts.get(sessionId);
      if (text) {
        aiSelectionDrafts.delete(sessionId);
        setDraft((previous) =>
          [previous, "终端选中的内容：\n" + text].filter(Boolean).join("\n\n"),
        );
      }
    };
    receive();
    const handler = (event: Event) => {
      if ((event as CustomEvent<string>).detail === sessionId) receive();
    };
    window.addEventListener("termpilot:ai-selection", handler);
    return () => window.removeEventListener("termpilot:ai-selection", handler);
  }, [sessionId]);
  function editDraft(text:string) {
    setDraft(text);
    if(current.current.id && current.current.status!=="running") draftWriter.enqueue({conversationId:current.current.id,draft:text});
  }
  function restore(chat:AIValue) {
    current.current=chat;
    setConversation(chat);
    setDraft(chat.draft ?? "");
    setAgent(chat.agent ?? "");
    setModel(chat.model ?? "");
    setFiles((chat.attachments ?? []).map((item:AIValue)=>item.path).filter(Boolean));
    setSelectedSkills(chat.skills ?? []);
  }
  const scopedTargets=()=>context().sessions.filter(target=>target.scope===scope);
  const selection=()=>scopedTargets().map(target=>terminalSelections.get(target.sessionId)?.()).find(Boolean) ?? "";
  useEffect(()=>{
    const off=getCurrentWindow().onDragDropEvent(({payload})=>{
      if(payload.type!=="drop" || !composer.current || current.current.status==="running")return;
      const r=composer.current.getBoundingClientRect();
      const x=payload.position.x/window.devicePixelRatio,y=payload.position.y/window.devicePixelRatio;
      if(x>=r.left && x<r.right && y>=r.top && y<r.bottom) setFiles(items=>[...new Set([...items,...payload.paths])]);
    });
    return ()=>{void off.then(unlisten=>unlisten()).catch(()=>{});void draftWriter.flush().catch(()=>{});};
  },[draftWriter]);
  const providers: AIValue[] = (settings.providers ?? []).filter((p:AIValue)=>p.enabled!==false);
  const agents: AIValue[] = (settings.agents ?? []).filter((item:AIValue)=>agentCatalog.find(a=>a.kind===item.kind)?.available!==false);
  const external=agents.some(item=>item.id===agent);
  const running = conversation.status === "running";
  async function guard(work: () => Promise<unknown>) {
    try {
      setError("");
      await work();
    } catch (e) {
      setError(String(e));
    }
  }
  useEffect(() => {
    const refresh = () => {
      void guard(async () => {
        const c = await ai("settings.get");
        setSettings(c.settings);
        setAgentCatalog(c.agents ?? []);
      });
    };
    window.addEventListener("termpilot:ai-settings-changed", refresh);
    return () =>
      window.removeEventListener("termpilot:ai-settings-changed", refresh);
  }, []);
  async function histories() {
    setHistory(await ai<AIValue[]>("conversation.list", { scope }));
  }
  useEffect(() => {
    let live = true;
    void guard(async () => {
      const c = await ai("settings.get");
      if (!live) return;
      setSettings(c.settings);
      setAgentCatalog(c.agents ?? []);
      setAgent(
        c.settings.selected || (c.settings.providers?.find((p: AIValue) => p.enabled !== false)?.id ??
          c.settings.agents?.[0]?.id ??
          ""),
      );
      const [items, availableSkills] = await Promise.all([
        ai<AIValue[]>("conversation.list", {scope}), ai<AIValue[]>("skills.list"),
      ]);
      if (!live) return;
      setSkills(availableSkills ?? []);
      setHistory(items);
      if (items.length) {
        const chat = await ai("conversation.get", {
          conversationId: items[0].id,
        });
        if (!live) return;
        restore(chat);
        setPending(
          [...aiInteractions.values()].filter(
            (p) => p.conversationId === chat.id,
          ),
        );
      }
    });
    const off = listen<AIValue>("ai-event", ({ payload: e }) => {
      if (!live) return;
      if (e.type === "conversation") {
        if (e.conversation?.scope === scope) void histories();
        if (e.conversationId === current.current.id) {
          setConversation(e.conversation);
          setStream("");
        }
      }
      if (e.conversationId && e.conversationId !== current.current.id) return;
      if (e.type === "delta") setStream((s) => s + (e.text ?? ""));
      if (["approval", "question", "form"].includes(e.type))
        setPending((p) => [...p, e]);
      if (e.type === "interactionClosed")
        setPending((p) => p.filter((x) => x.requestId !== e.requestId));
      if (e.type === "error" || e.type === "commandTimeout")
        setError(e.message);
    });
    return () => {
      live = false;
      void off.then((f) => f());
    };
  }, [sessionId]);
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => {
      void ai("chat.render", {
        messages: conversation.messages ?? [],
        status: conversation.status,
        streaming: stream,
        interactions: pending,
      })
        .then((r) => {
          if (live) setRows(r.rows ?? []);
        })
        .catch((e) => {
          if (live) setError(String(e));
        });
    }, 50);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [conversation, stream, pending]);
  useEffect(() => {
    if (following.current)
      scroll.current?.scrollTo({ top: scroll.current.scrollHeight });
    else setLatest(true);
  }, [rows]);
  async function create() {
    if (running) throw Error("请先停止当前任务");
    await draftWriter.flush();
    const c = await ai("conversation.create", { scope, agent });
    setConversation(c);
    setStream("");
    setPending([]);
    await histories();
    return c;
  }
  async function send() {
    const command=draft.trim();
    if (command==="/stop" || command==="/compact") {
      if(!conversation.id) return;
      await draftWriter.flush();
      await ai(command==="/stop" ? "turn.stop" : "conversation.compact", {conversationId:conversation.id});
      editDraft(""); return;
    }
    if (!command || running) return;
    await draftWriter.flush();
    if (!agent) throw Error("请先在设置 → AI 中配置提供商或外部 Agent");
    const c = conversation.id ? conversation : await create();
    const text = draft;
    await ai("conversation.draft", {
      conversationId: c.id,
      draft: text,
      agent,
      model,
      skills:selectedSkills,
      attachments: files.map((path) => ({
        path,
        name: path.split(/[\\/]/).pop(),
      })),
    });
    await ai("turn.start", { conversationId: c.id, text });
    setDraft("");
    setFiles([]);
    following.current = true;
  }
  async function reply(frame: AIValue, value: AIValue) {
    await ai("interaction.reply", { requestId: frame.requestId, value });
    setPending((p) => p.filter((x) => x.requestId !== frame.requestId));
  }
  async function exportChat() {
    const path = await save({
      defaultPath: "TermPilot-对话.md",
      filters: [
        { name: "Markdown", extensions: ["md"] },
        { name: "JSON", extensions: ["json"] },
        { name: "Plain text", extensions: ["txt"] },
      ],
    });
    if (path) {
      const r = await ai("conversation.export", {
        conversationId: conversation.id,
        format: path.toLowerCase().endsWith(".json") ? "json" : path.toLowerCase().endsWith(".txt") ? "txt" : "md",
      });
      await invoke("local_write_text", { path, text: r.text });
    }
  }
  return (
    <section className="ai-panel">
      <header className="ai-header">
        <Sparkles size={17} />
        <ThemedSelect
          className="ai-agent-select"
          label="Agent"
          value={external ? agent : "builtin"}
          placeholder="TermPilot Agent"
          disabled={running}
          onChange={value=>{
            if(value==="settings"){useAppStore.getState().setNavigation("ai");return;}
            setAgent(value==="builtin" ? providers[0]?.id ?? "" : value);setModel("");
          }}
          options={[
            {value:"builtin",label:"TermPilot Agent"},
            ...agents.map(p=>({value:p.id,label:p.name,group:"外部 Agent"})),
            {value:"settings",label:"Agent 设置"},
          ]}
        />
        <button title="历史对话" onClick={() => setShowHistory(!showHistory)}>
          <History size={16} />
        </button>
        <button
          title="新建对话"
          disabled={running}
          onClick={() =>
            void guard(async () => {
              restore(await create());
            })
          }
        >
          <SquarePen size={16} />
        </button>
        <button
          title="AI 设置"
          onClick={() => useAppStore.getState().setNavigation("ai")}
        >
          <Settings size={16} />
        </button>
      </header>
      {showHistory && (
        <div className="ai-history">
          {history.map((c) => (
            <button
              key={c.id}
              disabled={running}
              onClick={() =>
                void guard(async () => {
                  await draftWriter.flush();
                  const chat = await ai("conversation.get", {
                    conversationId: c.id,
                  });
                  restore(chat);
                  setPending([...aiInteractions.values()].filter(p=>p.conversationId===chat.id));
                  setShowHistory(false);
                  setStream("");
                })
              }
            >
              {c.title || "新对话"}
            </button>
          ))}
          {conversation.id && (
            <>
              <button onClick={() => void guard(exportChat)}>导出对话</button>
              <button
                disabled={running}
                onClick={() =>
                  void guard(async () => {
                    await draftWriter.flush();
                    await ai("conversation.delete", {
                      conversationId: conversation.id,
                    });
                    restore({agent});
                    setPending([]); setStream("");
                    await histories();
                  })
                }
              >
                删除当前对话
              </button>
            </>
          )}
        </div>
      )}
      {error && (
        <div className="ai-error" role="alert">
          {error}
        </div>
      )}
      <div
        className="ai-messages"
        ref={scroll}
        onScroll={() => {
          const s = scroll.current!;
          following.current =
            s.scrollHeight - s.scrollTop - s.clientHeight < 48;
          if (following.current) setLatest(false);
        }}
      >
        {rows.length === 0 && (
          <div className="ai-empty">
            <Sparkles size={38} />
            <h3>与 {label} 对话</h3>
            <p>询问服务器状态、分析终端输出或获取配置帮助</p>
            {!agent && (
              <button
                className="ai-setup-button"
                onClick={() => useAppStore.getState().setNavigation("ai")}
              >
                配置 AI
              </button>
            )}
          </div>
        )}
        {rows.map((row) =>
          row.kind === "tools" ? (
            <div className="ai-tools" key={row.id}>
              {row.tools.map((tool: AIValue) => (
                <details
                  key={tool.id}
                  open={tool.state === "approval" ? true : undefined}
                >
                  <summary>
                    <ChevronDown size={12} />
                    <span>{tool.summary}</span>
                    <i data-state={tool.state}>
                      {(
                        {
                          completed: "✓",
                          error: "✕",
                          running: "◌",
                          approval: "◇",
                        } as AIValue
                      )[tool.state] ?? "•"}
                    </i>
                  </summary>
                  <div className="ai-tool-detail">
                    <small>参数</small>
                    <pre>{tool.arguments}</pre>
                    {tool.output && (
                      <>
                        <small>结果</small>
                        <pre>{tool.output}</pre>
                      </>
                    )}
                    {tool.approval && (
                      <div className="ai-approval">
                        <button
                          onClick={() =>
                            void guard(() =>
                              reply(tool.approval, { allow: false }),
                            )
                          }
                        >
                          拒绝
                        </button>
                        <button
                          onClick={() =>
                            void guard(() =>
                              reply(tool.approval, { allow: true }),
                            )
                          }
                        >
                          允许
                        </button>
                        <button
                          onClick={() =>
                            void guard(() =>
                              reply(tool.approval, {
                                allow: true,
                                remember: true,
                              }),
                            )
                          }
                        >
                          本次会话记住
                        </button>
                      </div>
                    )}
                  </div>
                </details>
              ))}
            </div>
          ) : (
            <article className={`ai-message ai-${row.role}`} key={row.id}>
              {row.role === "user" ? (
                row.text
              ) : (
                <Markdown blocks={row.blocks ?? []} />
              )}
            </article>
          ),
        )}
        {pending
          .filter((p) => p.type !== "approval")
          .map((p) => (
            <AIInteraction
              key={p.requestId}
              frame={p}
              onReply={(v) => void guard(() => reply(p, v))}
            />
          ))}
        {running && (
          <div className="ai-status">
            {pending.length ? "等待你的确认" : "正在处理…"}
          </div>
        )}
      </div>
      {latest && (
        <button
          className="ai-latest"
          onClick={() => {
            following.current = true;
            setLatest(false);
            scroll.current?.scrollTo({ top: scroll.current.scrollHeight });
          }}
        >
          ↓ 回到最新
        </button>
      )}
      <form
        ref={composer} className="ai-composer"
        onSubmit={(e) => {
          e.preventDefault();
          void guard(send);
        }}
      >
        {draft.startsWith("/") && !draft.includes("\n") && <div className="ai-composer-suggestions">
          {(settings.quickMessages ?? []).filter((q:AIValue)=>q.slug?.toLowerCase().includes(draft.slice(1).toLowerCase())).map((q:AIValue)=>
            <button key={q.id} type="button" onClick={()=>editDraft(q.content ?? "")}>/{q.slug} · {q.name}</button>)}
          {["/compact","/stop"].map(cmd=><button type="button" key={cmd} onClick={()=>editDraft(cmd)}>{cmd} · {cmd==="/stop"?"停止任务":"压缩上下文"}</button>)}
        </div>}
        {draft.endsWith("@") && <div className="ai-composer-suggestions">
          {scopedTargets().map(target=><button type="button" key={target.sessionId} onClick={()=>editDraft(draft.slice(0,-1)+"[终端："+target.label+"，sessionId："+target.sessionId+"] ")}>{target.label}</button>)}
          <button type="button" onClick={()=>editDraft(draft.slice(0,-1)+selection())}>当前终端选区</button>
        </div>}
        <textarea
          placeholder="询问服务器…  @ 引用 · / 快捷消息"
          value={draft}
          onChange={(e) => editDraft(e.target.value)}
          onKeyDown={(e) => {
            if (
              e.key === "Enter" &&
              !e.shiftKey &&
              !e.nativeEvent.isComposing
            ) {
              e.preventDefault();
              void guard(send);
            }
          }}
        />
        {files.length > 0 && (
          <div className="ai-attachments">
            {files.map((f) => (
              <button
                key={f}
                type="button"
                onClick={() => setFiles(files.filter((x) => x !== f))}
              >
                {f.split(/[\\/]/).pop()} ×
              </button>
            ))}
          </div>
        )}
        {!external && <AIModelPicker providers={providers} providerId={agent} model={model}
          pins={settings.pinnedModels ?? []} disabled={running}
          choose={(provider,name)=>{setAgent(provider);setModel(name);}}
          changePins={async pinnedModels=>{
            const next={...settings,pinnedModels};await ai("settings.save",{settings:next});setSettings(next);
          }}/>}
        <footer>
          <button
            type="button"
            title="添加附件"
            onClick={() =>
              void guard(async () => {
                const paths = await open({ multiple: true });
                if (paths)
                  setFiles(items=>[...new Set([...items,...(Array.isArray(paths) ? paths : [paths])])]);
              })
            }
          >
            <Paperclip size={15} />
          </button>
          <ThemedSelect label="添加上下文" value="" placeholder="上下文" options={[
            {value:"selection",label:"附上终端选区"},
            ...skills.map(skill=>({value:"skill:"+skill.id,label:(selectedSkills.includes(skill.id)?"✓ ":"")+(skill.name ?? skill.id)})),
          ]} onChange={value=>{
            if(value==="selection"){const text=selection();if(text)editDraft(draft+"\n<terminal-selection>\n"+text+"\n</terminal-selection>");}
            else {const id=value.slice(6);setSelectedSkills(ids=>ids.includes(id)?ids.filter(other=>other!==id):[...ids,id]);}
          }}/>
          <ThemedSelect
            label="权限模式"
            value={settings.mode ?? "confirm"}
            options={[
              { value: "observe", label: "观察者" },
              { value: "confirm", label: "确认" },
              { value: "auto", label: "自动" },
            ]}
            onChange={(mode) =>
              void guard(async () => {
                const next = { ...settings, mode };
                await ai("settings.save", { settings: next });
                setSettings(next);
              })
            }
          />
          <ThemedSelect
            value=""
            label="更多操作"
            placeholder="…"
            options={[
              { value: "compact", label: "压缩上下文" },
              { value: "export", label: "导出对话" },
              ...(settings.quickMessages ?? []).map((q: AIValue) => ({
                value: `quick:${q.id}`,
                label: `/${q.slug} · ${q.name}`,
              })),
            ]}
            onChange={(action) => {
              if (action === "compact")
                void guard(() =>
                  ai("conversation.compact", {
                    conversationId: conversation.id,
                  }),
                );
              if (action === "export") void guard(exportChat);
              if (action.startsWith("quick:"))
                setDraft(
                  (settings.quickMessages ?? []).find(
                    (q: AIValue) => q.id === action.slice(6),
                  )?.content ?? "",
                );
            }}
          />
          <span />
          {running ? (
            <button
              type="button"
              title="停止"
              onClick={() =>
                void guard(() =>
                  ai("turn.stop", { conversationId: conversation.id }),
                )
              }
            >
              <Square size={15} />
            </button>
          ) : (
            <button
              className="primary"
              type="submit"
              disabled={!draft.trim() || !agent}
              title="发送"
            >
              <ArrowUp size={17} />
            </button>
          )}
        </footer>
      </form>
    </section>
  );
}
export function AIInteraction({
  frame,
  onReply,
}: {
  frame: AIValue;
  onReply: (v: AIValue) => void;
}) {
  const [values, setValues] = useState<AIValue>({});
  const fields: AIValue[] =
    frame.type === "question"
      ? (frame.payload.questions ?? []).map((q: AIValue) => ({
          ...q,
          name: q.id,
          label: q.question,
          type: q.isSecret ? "password" : "text",
        }))
      : (frame.payload.fields ?? []);
  return (
    <form
      className="ai-interaction"
      onSubmit={(e) => {
        e.preventDefault();
        onReply(
          frame.type === "question"
            ? {
                answers: Object.fromEntries(
                  fields.map((f) => [
                    f.name,
                    {
                      answers: Array.isArray(values[f.name])
                        ? values[f.name]
                        : [values[f.name] ?? ""],
                    },
                  ]),
                ),
              }
            : { values },
        );
      }}
    >
      <strong>{frame.payload.title ?? "Agent 需要补充信息"}</strong>
      {fields.map((f) => (
        <label key={f.name}>
          {f.label}
          {f.type === "checkbox" ? (
            <input
              type="checkbox"
              checked={!!values[f.name]}
              onChange={(e) =>
                setValues({ ...values, [f.name]: e.target.checked })
              }
            />
          ) : f.options?.length ? (
            <select
              value={values[f.name] ?? ""}
              onChange={(e) =>
                setValues({ ...values, [f.name]: e.target.value })
              }
            >
              <option value="">请选择</option>
              {f.options.map((o: AIValue, i: number) => (
                <option
                  key={i}
                  disabled={o.disabled}
                  value={o.value ?? o.label}
                >
                  {o.label}
                </option>
              ))}
            </select>
          ) : (
            <input
              type={f.type === "password" ? "password" : "text"}
              required={f.required}
              value={values[f.name] ?? ""}
              onChange={(e) =>
                setValues({ ...values, [f.name]: e.target.value })
              }
            />
          )}
        </label>
      ))}
      <footer>
        <button type="button" onClick={() => onReply({ cancelled: true })}>
          取消
        </button>
        <button type="submit">提交</button>
      </footer>
    </form>
  );
}
