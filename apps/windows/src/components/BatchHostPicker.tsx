import { useEffect, useRef, useState } from "react";
import { ChevronDown, ChevronRight, Folder, Server, X } from "lucide-react";
import type { Host, HostGroup } from "../types";
import { useTranslation } from "../i18n";
import { groupPath, hostEndpoint, hostTreeRows, matchingHosts, selectableHosts, toggleSelection } from "../batchPresentation";
import { buildHostGroupTree } from "./Sidebar";

export function BatchHostPicker({ hosts, groups, added, onAdd, onClose }: {
  hosts: Host[]; groups: HostGroup[]; added: Host[];
  onAdd: (hosts: Host[]) => void; onClose: () => void;
}) {
  const t = useTranslation();
  const dialog = useRef<HTMLDialogElement>(null);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(new Set<string>());
  const [expanded, setExpanded] = useState(() => new Set([...buildHostGroupTree(groups).map(n => n.group.id), "ungrouped"]));
  const available = selectableHosts(hosts);
  const endpoints = new Set(added.map(hostEndpoint));
  const already = new Set(available.filter(h => endpoints.has(hostEndpoint(h))).map(h => h.id));
  const shown = matchingHosts(available, groups, query);
  const rows = hostTreeRows(available, groups, query, expanded);
  const selectedHosts = available.filter(h => selected.has(h.id) && !already.has(h.id));
  const chosenHosts = available.filter(h => selected.has(h.id) || already.has(h.id));
  function toggleExpanded(id: string) { setExpanded(current => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; }); }
  function toggle(ids: string[]) { setSelected(current => toggleSelection(current, ids, already)); }
  useEffect(() => { const d = dialog.current!; d.showModal(); return () => d.close(); }, []);
  return <dialog ref={dialog} className="batch-host-picker" aria-labelledby="batch-picker-title" onCancel={e => {e.preventDefault(); e.stopPropagation(); onClose();}}>
    <h2 id="batch-picker-title">{t("Add saved host")}</h2>
    <p>{t("Expand groups to select hosts, or select a whole group including its subgroups.")}</p>
    <input autoFocus aria-label={t("Search hosts or groups")} placeholder={t("Search hosts or groups")} value={query} onChange={e => { setQuery(e.target.value); if (e.target.value.trim()) setExpanded(new Set([...groups.map(g => g.id), "ungrouped"])); }} />
    <div className="batch-actions"><button type="button" onClick={() => setSelected(new Set([...selected, ...shown.filter(h => !already.has(h.id)).map(h => h.id)]))}>{t(query ? "Select matching hosts" : "Select all hosts")}</button><button type="button" onClick={() => setSelected(new Set())}>{t("Clear selection")}</button><span>{selectedHosts.length} {t("hosts to add")}</span></div>
    <div className="batch-picker-columns"><section aria-label={t("Groups")}><h3>{t("Groups")}</h3>
      {rows.map(row => {
        const count = row.hostIds.filter(id => already.has(id) || selected.has(id)).length;
        const checked = count === row.hostIds.length;
        const name = row.group?.name ?? t("Ungrouped");
        return <div key={row.id} className="batch-picker-tree-row" style={{paddingLeft: row.depth * 16}}>
          {row.host ? <label className="batch-picker-choice"><Selection title={`${row.host.label} · ${row.host.hostname}`} checked={checked} disabled={already.has(row.host.id)} onChange={() => toggle(row.hostIds)}/><Server size={15}/><span><HostLabel host={row.host}/>{already.has(row.host.id) && <small>{t("Already added")}</small>}</span></label>
            : <div className="batch-picker-group-row"><button type="button" className="batch-picker-expand" aria-expanded={row.expanded} aria-label={`${t(row.expanded ? "Collapse group" : "Expand group")} ${name}`} onClick={() => toggleExpanded(row.id)}>{row.expanded ? <ChevronDown size={14}/> : <ChevronRight size={14}/>}</button><Selection title={name} checked={checked} mixed={count > 0 && !checked} disabled={row.hostIds.every(id => already.has(id))} onChange={() => toggle(row.hostIds)}/><button type="button" className="batch-picker-group-name" aria-expanded={row.expanded} onClick={() => toggleExpanded(row.id)}><Folder size={17}/><strong>{name}</strong><small>{count} / {row.hostIds.length}</small></button></div>}
        </div>;
      })}
      {!shown.length && <p>{t("No matching SSH hosts")}</p>}
    </section><section aria-label={t("Selected hosts")}><h3>{t("Selected hosts")}<small>{chosenHosts.length}</small></h3>
      {chosenHosts.map(host => <div className="batch-picker-selected-host" key={host.id}><Server size={15}/><div><HostLabel host={host}/><small>{groupPath(host.groupId, groups) || t("Ungrouped")}</small>{already.has(host.id) && <small>{t("Already added")}</small>}</div>{!already.has(host.id) && <button type="button" aria-label={`${t("Remove")} ${host.label}`} onClick={() => setSelected(current => { const next = new Set(current); next.delete(host.id); return next; })}><X size={14}/></button>}</div>)}
      {!chosenHosts.length && <p>{t("Select hosts from the groups on the left.")}</p>}
    </section></div>
    <footer><button type="button" onClick={onClose}>{t("Cancel")}</button><button type="button" className="primary-button" disabled={!selectedHosts.length} onClick={() => { onAdd(selectedHosts); onClose(); }}>{t("Add selected hosts")} ({selectedHosts.length})</button></footer>
  </dialog>;
}
function HostLabel({host}: {host: Host}) {
  return <><span title={host.label}>{host.label}</span><small>{host.hostname.includes(":") ? `[${host.hostname}]` : host.hostname}:{host.port}</small></>;
}
function Selection({ title, checked, mixed = false, disabled, onChange }: { title: string; checked: boolean; mixed?: boolean; disabled?: boolean; onChange: () => void }) {
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => { if (input.current) input.current.indeterminate = mixed; }, [mixed]);
  return <input ref={input} type="checkbox" aria-label={title} checked={checked} aria-checked={mixed ? "mixed" : checked} disabled={disabled} onChange={onChange} />;
}
