import { useBatchWorkspace, batchTabTitle } from "../batchWorkspace";
import { useTranslation } from "../i18n";
import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
interface Prompt {
  sessionId: string;
  promptID: string;
  targetId?: string;
  ip?: string;
  type: string;
  message?: string;
  detail?: {
    hostPattern: string;
    algorithm: string;
    fingerprint: string;
    hasHostPattern: boolean;
  };
}
export function EnginePrompt() {
  const [queue, setQueue] = useState<Prompt[]>([]);
  const [answer, setAnswer] = useState({key:"", secret:"", error:""});
  const t=useTranslation(), {tabs,selected}=useBatchWorkspace();
  const jobFor=(p:Prompt)=>tabs.find(tab=>p.sessionId==="batch:"+tab.store.getState().runId);
  const prompt=queue.find(p=>!p.sessionId.startsWith("batch:")) ?? queue.find(p=>jobFor(p)?.id===selected) ?? queue[0];
  const promptKey=prompt && JSON.stringify([prompt.sessionId,prompt.promptID]);
  const {secret,error}=answer.key===promptKey ? answer : {secret:"",error:""};
  const owner=prompt && jobFor(prompt);
  const replying=useRef(new Set<string>());
  useEffect(()=>{
    for(const tab of tabs) { const s=tab.store.getState(), waiting=queue.some(p=>p.sessionId==="batch:"+s.runId);
      if(s.waitingPrompt!==waiting)tab.store.setState({waitingPrompt:waiting}); }
  },[queue,tabs]);
  useEffect(() => {
    const off = listen<Prompt>("engine-prompt", ({ payload }) =>
      setQueue((q) => [...q, payload]),
    );
    const batchOff = listen<{runId: string; type: string; stage?: string; targetId?: string}>("batch-event", ({payload}) => {
      if (["batchFinished", "exit"].includes(payload.type) || payload.stage === "finished") {
        setQueue(q => q.filter(p => p.sessionId !== `batch:${payload.runId}` || (payload.stage === "finished" && p.targetId !== payload.targetId)));
      }
    });
    return () => {
      void batchOff.then(f => f());
      void off.then((f) => f());
    };
  }, []);

  async function reply(accepted: boolean) {
    if (!prompt || !promptKey || replying.current.has(promptKey)) return;
    replying.current.add(promptKey);
    try {
      await invoke("engine_prompt_reply", {
        sessionId: prompt.sessionId,
        promptId: prompt.promptID,
        ...(prompt.type === "hostKeyPrompt"
          ? { accepted }
          : { value: accepted ? secret : null }),
      });
      setQueue(q=>q.filter(p=>p.promptID!==prompt.promptID || p.sessionId!==prompt.sessionId));
      setAnswer(current=>current.key===promptKey ? {key:"",secret:"",error:""} : current);
    } catch (e) {
      setAnswer(current=>current.key && current.key!==promptKey ? current : {key:promptKey,secret,error:String(e)});
    } finally { replying.current.delete(promptKey); }
  }
  if (!prompt) return null;
  return (
    <div className={owner?"batch-prompt-card":"modal-backdrop"}>
      <form
        className={owner?"batch-prompt-form":"modal-card"}
        onSubmit={(e) => {
          e.preventDefault();
          void reply(true);
        }}
      >
        <h2>
          {owner && batchTabTitle(owner,t)+" · "}{t(prompt.type === "hostKeyPrompt" ? "Verify server identity" : "Connection authentication")}
        </h2>
        {prompt.ip && <p>{prompt.ip}</p>}
        {prompt.detail ? (
          <>
            <p>
              {prompt.detail.hasHostPattern
                ? t("Server key changed. Verify the fingerprint.")
                : t("First connection. Verify the fingerprint.")}
            </p>
            <p>
              {prompt.detail.hostPattern} · {prompt.detail.algorithm}
            </p>
            <code>{prompt.detail.fingerprint}</code>
          </>
        ) : (
          <label>
            {prompt.message}
            <input
              autoFocus
              type="password"
              value={secret}
              onChange={(e) => setAnswer({key:promptKey!,secret:e.target.value,error:""})}
            />
          </label>
        )}
        {error && <p role="alert">{error}</p>}
        <footer>
          <button type="button" onClick={() => void reply(false)}>
            {t("Cancel")}
          </button>
          <button type="submit">
            {t(prompt.type === "hostKeyPrompt" ? "Trust and connect" : "Continue")}
          </button>
        </footer>
      </form>
    </div>
  );
}
