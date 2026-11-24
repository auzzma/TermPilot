import { Fragment, useState } from "react";
import { useAppStore } from "../store";
import { useTranslation } from "../i18n";
import { configureQuickCredential, quickCredentialProtocols, readQuickCredential, supportsQuickCredential, type QuickCredentialStrategy } from "../quickCredentials";

export const quickProtocolNames = { ssh: "SSH", standardVNC: "Standard VNC", highPerformance: "Apple High Performance", rdp: "RDP" };

export function QuickCredentialSettings() {
  const credentials = useAppStore(state => state.credentials);
  const t = useTranslation();
  const [, refresh] = useState(0);
  const [error, setError] = useState("");
  return <section className="settings-card quick-credential-settings">
    <h3>{t("Quick Connect Credentials")}</h3>
    <div>
    {quickCredentialProtocols.map(protocol => {
      const preference = readQuickCredential(protocol);
      const available = credentials.filter(c => supportsQuickCredential(protocol, c));
      function update(strategy: QuickCredentialStrategy, fixed: string) {
        try { configureQuickCredential(protocol, strategy, fixed); setError(""); refresh(n => n + 1); }
        catch { setError(t("Could not save credential preferences.")); }
      }
      return <Fragment key={protocol}>
        <label className="form-field"><span>{t(quickProtocolNames[protocol])}</span>
          <select aria-label={`${t(quickProtocolNames[protocol])} ${t("Credential strategy")}`} value={preference.strategy}
            onChange={e => update(e.target.value as QuickCredentialStrategy, preference.fixed)}>
            <option value="manual">{t("Choose each time")}</option>
            <option value="recent">{t("Remember last successful credential")}</option>
            <option value="fixed">{t("Fixed credential")}</option>
          </select>
        </label>
        {preference.strategy === "fixed" && <label className="form-field"><span>{t("Fixed credential")}</span><select aria-label={`${t(quickProtocolNames[protocol])} ${t("Credential")}`}
          value={preference.fixed} onChange={e => update("fixed", e.target.value)}>
          <option value="">{t("Select credential")}</option>
          {preference.fixed && !available.some(c => c.id === preference.fixed) && <option value={preference.fixed} disabled>{t("Credential unavailable. Select again.")}</option>}
          {available.map(c => <option key={c.id} value={c.id}>{c.label} · {c.username}</option>)}
        </select></label>}
      </Fragment>;
    })}
    </div>
    {error && <p role="alert">{error}</p>}
  </section>;
}
