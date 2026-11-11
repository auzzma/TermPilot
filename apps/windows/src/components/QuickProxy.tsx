import type { ProxyConfiguration } from "../types";
import { useAppStore } from "../store";
export function QuickProxy({
  profileId,
  config,
  onChange,
}: {
  profileId: string;
  config?: ProxyConfiguration;
  onChange: (id: string, config?: ProxyConfiguration) => void;
}) {
  const profiles = useAppStore((s) => s.proxies);
  const credentials = useAppStore((s) => s.credentials);
  const custom = !!config;
  const update = (v: Partial<ProxyConfiguration>) =>
    onChange("", { type: "socks5", host: "", port: 1080, ...config, ...v });
  return (
    <div className="quick-proxy">
      <label className="quick-connect-row">
        <span className="quick-connect-label">代理</span>
        <select
          value={custom ? "custom" : profileId}
          onChange={(e) =>
            e.target.value === "custom" ? update({}) : onChange(e.target.value)
          }
        >
          <option value="">不使用代理</option>
          <option value="custom">自定义代理</option>
          {profiles.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
      </label>
      {config && (
        <>
          <label className="quick-connect-row">
            <span className="quick-connect-label">类型</span>
            <select
              value={config.type}
              onChange={(e) =>
                update({ type: e.target.value as ProxyConfiguration["type"] })
              }
            >
              <option value="socks5">SOCKS5</option>
              <option value="http">HTTP CONNECT</option>
              <option value="command">ProxyCommand</option>
            </select>
          </label>
          {config.type === "command" ? (
            <label className="quick-connect-row">
              <span className="quick-connect-label">命令</span>
              <input
                value={config.command ?? ""}
                onChange={(e) => update({ command: e.target.value })}
              />
            </label>
          ) : (
            <>
              <label className="quick-connect-row">
                <span className="quick-connect-label">代理地址</span>
                <input
                  value={config.host}
                  onChange={(e) => update({ host: e.target.value })}
                />
                <input
                  style={{ width: 70 }}
                  aria-label="代理端口"
                  type="number"
                  min={1}
                  max={65535}
                  value={config.port}
                  onChange={(e) => update({ port: Number(e.target.value) })}
                />
              </label>
              <label className="quick-connect-row">
                <span className="quick-connect-label">代理凭证</span>
                <select
                  value={config.credentialId ?? ""}
                  onChange={(e) =>
                    update({ credentialId: e.target.value || undefined })
                  }
                >
                  <option value="">自定义 / 无认证</option>
                  {credentials
                    .filter((c) => c.kind === "password")
                    .map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.label}
                      </option>
                    ))}
                </select>
              </label>
              {!config.credentialId && (
                <>
                  <label className="quick-connect-row">
                    <span className="quick-connect-label">代理用户名</span>
                    <input
                      value={config.username ?? ""}
                      onChange={(e) => update({ username: e.target.value })}
                    />
                  </label>
                  <label className="quick-connect-row">
                    <span className="quick-connect-label">代理密码</span>
                    <input
                      type="password"
                      value={config.password ?? ""}
                      onChange={(e) => update({ password: e.target.value })}
                    />
                  </label>
                </>
              )}
            </>
          )}
        </>
      )}
    </div>
  );
}
