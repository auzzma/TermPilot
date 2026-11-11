import type { BatchHostResult } from "./batchResults";
export type CSVScope = "all" | "failed" | "success";
type Translate = (s:string) => string;
function reason(host: BatchHostResult, t: Translate) {
  if (host.status !== "failed") return "";
  const seen = new Set<string>(), lines = new Set<string>();
  for (const event of [...host.failedSteps, ...(host.final ? [host.final] : [])]) {
    let details = [event.message && t(event.message), event.error && t(event.error), event.stderr,
      event.exitCode ? t("Exit code")+" "+event.exitCode : ""].filter((s):s is string=>!!s?.trim());
    if (event.stage==="finished") details=details.filter(s=>!seen.has(s));
    for (const detail of details) seen.add(detail);
    if (details.length) lines.add((event.stage==="finished" ? "" : t(event.stage!)+" · ")+details.join("\n"));
  }
  return lines.size ? [...lines].join("\n") : [...host.failedSteps.map(e=>t(e.stage!)), t("No failure details recorded.")].join(" · ");
}
export function batchResultsCSV(hosts:BatchHostResult[], scope:CSVScope, t:Translate) {
  const line = (cells:string[]) => cells.map(cell=>{
    const value = /^[=+\-@]/.test(cell.trimStart()) ? "'"+cell : cell;
    return '"'+value.replace(/"/g,'""')+'"';
  }).join(",")+"\r\n";
  const headers = scope==="success" ? ["Host IP","Status"] : ["Host IP","Status","Failure reason"];
  return "\uFEFF"+line(headers.map(t))+hosts.filter(h=>scope==="all" || h.status===scope).map(h=>
    line(scope==="success" ? [h.ip,t(h.status)] : [h.ip,t(h.status),reason(h,t)])).join("");
}
