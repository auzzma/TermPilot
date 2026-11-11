import { useState } from "react";
import { BookOpen, MoreHorizontal, Save } from "lucide-react";
import { BatchDialog } from "./BatchDialog";
import { useTranslation } from "../i18n";
import { batchTabTitle, type BatchTab } from "../batchWorkspace";
import { useBatchLibrary, loadBatchLibrary, saveBatchJob, openSavedBatchJob, renameSavedBatchJob, deleteSavedBatchJob,
  parseConfiguration, type SavedBatchJob } from "../batchPersistence";

export function BatchLibraryButton() {
  const t = useTranslation(), ready = useBatchLibrary(s => s.ready);
  const [showing, setShowing] = useState(false);
  return <><button className="batch-library-button" disabled={!ready} onClick={() => {setShowing(true); void loadBatchLibrary().catch(() => undefined);}}><BookOpen size={14}/>{t("Job library")}</button>
    {showing && <BatchLibraryDialog onClose={() => setShowing(false)}/>}</>;
}
function BatchLibraryDialog({onClose}: {onClose: () => void}) {
  const t = useTranslation(), {items, error} = useBatchLibrary();
  const [search, setSearch] = useState("");
  const [renaming, setRenaming] = useState<SavedBatchJob>();
  const [deleting, setDeleting] = useState<SavedBatchJob>();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  async function perform(action: () => void | Promise<void>) {
    setBusy(true);
    try { await action(); } catch (e) { useBatchLibrary.setState({error: e instanceof Error ? e.message : String(e)}); }
    finally { setBusy(false); }
  }
  const filtered = items.filter(item => item.name.toLocaleLowerCase().includes(search.toLocaleLowerCase()));
  function summary(item: SavedBatchJob) {
    try {
      const value = parseConfiguration(item.configuration);
      return `${t({execute:"Batch execution", upload:"Batch upload", collect:"File collection", check:"Check connections & elevation"}[value.job.kind])} · ${value.targets.length} ${t("hosts")}`;
    } catch { return t("Invalid or unsupported saved job."); }
  }
  return <BatchDialog title={t("Job library")} className="batch-library-dialog" onClose={onClose}>
    <input aria-label={t("Search jobs")} placeholder={t("Search jobs")} value={search} onChange={e => setSearch(e.target.value)}/>
    {error && <p role="alert" className="batch-error">{t(error)}</p>}
    {!filtered.length && <div className="batch-empty"><p>{t(search ? "No matching jobs" : "No saved jobs")}</p><p>{t("Save a job to reuse its configuration and hosts.")}</p></div>}
    <div className="batch-library-list">{filtered.map(item => <div className="batch-library-row" key={item.id}>
      <button className="batch-library-name" onClick={() => void perform(() => {openSavedBatchJob(item); onClose();})}><strong>{item.name}</strong><small>{summary(item)}</small></button>
      <time>{new Date(item.updatedMs).toLocaleString()}</time>
      <button onClick={() => void perform(() => {openSavedBatchJob(item); onClose();})}>{t("Open job")}</button>
      <details><summary aria-label={t("More actions")}><MoreHorizontal size={16}/></summary><div className="batch-library-menu">
        <button onClick={() => void perform(() => {openSavedBatchJob(item, true); onClose();})}>{t("Open copy")}</button>
        <button onClick={e => {e.currentTarget.closest("details")!.open=false;setName(item.name);setRenaming(item);setDeleting(undefined);}}>{t("Rename")}</button>
        <button onClick={e => {e.currentTarget.closest("details")!.open=false;setDeleting(item);setRenaming(undefined);}}>{t("Delete")}</button>
      </div></details>
    </div>)}</div>
    {renaming && <form className="batch-library-edit" onSubmit={e => {e.preventDefault(); void perform(async () => {await renameSavedBatchJob(renaming, name);setRenaming(undefined);});}}>
      <label>{t("Rename job")}<input autoFocus value={name} maxLength={160} onChange={e => setName(e.target.value)}/></label>
      <button type="button" onClick={() => setRenaming(undefined)}>{t("Cancel")}</button><button disabled={busy || !name.trim()}>{t("Save")}</button>
    </form>}
    {deleting && <div className="batch-library-edit"><p>{t("Delete saved job?")} <strong>{deleting.name}</strong><br/><small>{t("Open drafts and execution history will be kept.")}</small></p>
      <button onClick={() => setDeleting(undefined)}>{t("Cancel")}</button><button disabled={busy} onClick={() => void perform(async () => {await deleteSavedBatchJob(deleting);setDeleting(undefined);})}>{t("Delete")}</button></div>}
    <p className="batch-muted">{t("Opening a job does not run it.")}</p>
  </BatchDialog>;
}

export function BatchSaveControls({tab}: {tab: BatchTab}) {
  const t = useTranslation(), {ready, draftStatus, error} = useBatchLibrary();
  const [editing, setEditing] = useState<"save" | "copy">();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  function show(mode: "save" | "copy") {setName(batchTabTitle(tab, t));setEditing(mode);}
  async function save(asCopy: boolean, title: string) {
    setBusy(true);
    try {await saveBatchJob(tab, title, asCopy);setEditing(undefined);} catch {/* Storage error remains visible. */}
    finally {setBusy(false);}
  }
  return <><div className="batch-save-controls"><div className="batch-new-actions">
    <button disabled={!ready || busy} onClick={() => tab.savedId ? void save(false, batchTabTitle(tab,t)) : show("save")}><Save size={14}/>{t("Save job")}</button>
    <details><summary aria-label={t("Save job as")}>▾</summary><div><button disabled={!ready || busy} onClick={e => {e.currentTarget.closest("details")!.open=false;show("copy");}}>{t("Save job as")}</button></div></details>
  </div>{draftStatus && <small role="status">{t(draftStatus)}</small>}</div>
  {editing && <BatchDialog title={t(editing === "copy" ? "Save job as" : "Save job")} onClose={() => {if (!busy) setEditing(undefined);}} className="batch-save-dialog">
    <form onSubmit={e => {e.preventDefault();void save(editing === "copy", name);}}>
      <label>{t("Job name")}<input autoFocus value={name} maxLength={160} onChange={e => setName(e.target.value)}/></label>
      <p className="batch-muted">{t("Saves configuration and host references. Temporary passwords must be entered again.")}</p>
      {error && <p role="alert" className="batch-error">{t(error)}</p>}
      <button className="batch-primary" disabled={busy || !name.trim()}>{t("Save")}</button>
    </form>
  </BatchDialog>}</>;
}
