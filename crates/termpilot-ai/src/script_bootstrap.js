// TermPilot nct compatibility API; runs only inside the isolated QuickJS worker.
(() => {
  const send = globalThis.__termpilotSend;
  let snapshot = JSON.parse(globalThis.__termpilotInitial || '{}');
  delete globalThis.__termpilotSend;
  delete globalThis.__termpilotInitial;
  let sequence = 0;
  const pending = new Map();
  function call(method, args = []) {
    if (pending.size >= 128) return Promise.reject(new Error('Too many pending script operations'));
    return new Promise((resolve, reject) => {
      const id = String(++sequence);
      pending.set(id, { resolve, reject });
      send(JSON.stringify({ type: 'call', id, method, args }));
    });
  }
  const sleep = ms => call('session.sleep', [Number(ms) || 0]);
  const notify = (method, args) => send(JSON.stringify({ type: 'notify', method, args }));
  function pattern(value, literal = false) {
    if (literal) return text => text.includes(String(value));
    if (value instanceof RegExp) return text => { value.lastIndex = 0; return value.test(text); };
    const match = String(value).match(/^\/(.*)\/([dgimsuvy]*)$/s);
    if (match) { const re = new RegExp(match[1], match[2]); return text => { re.lastIndex = 0; return re.test(text); }; }
    return text => text.includes(String(value));
  }
  async function wait(patterns, ms = 30000) {
    const deadline = Date.now() + Math.max(0, Math.min(Number(ms) || 30000, 86400000));
    do {
      const output = await call('screen.waitSnapshot');
      for (let i = 0; i < patterns.length; i++) if (patterns[i](output.text || '')) {
        await call('screen.consume', [output.position]);
        return { index: i, text: output.text };
      }
      if (Date.now() >= deadline) throw new Error('Timed out waiting for terminal output');
      await sleep(100);
    } while (true);
  }
  const screen = {
    send: (text, options = {}) => call('screen.send', [String(text ?? ''), options]),
    sendLine: (text, options = {}) => call('screen.sendLine', [String(text ?? ''), options]),
    getText: async (start, end) => { const result = await call('screen.getText', [start, end]); if (result && typeof result === 'object') { snapshot.screen = result; return result.text || ''; } return result; },
    clear: () => call('screen.clear'),
    waitForText: (text, ms) => wait([pattern(text, true)], ms),
    waitForRegex: (value, ms) => wait([pattern(value instanceof RegExp ? value : new RegExp(String(value), 'm'))], ms),
    waitFor: (value, ms) => wait([pattern(value)], ms),
    waitForAny: (values, ms) => wait(values.map(value => pattern(value)), ms),
    waitForPrompt: (ms = 60000) => wait([pattern(/(?:^|\n)[^\n]*[#$%>]\s*$/m)], ms),
    get rows() { return snapshot.screen?.rows || 24; },
    get cols() { return snapshot.screen?.cols || 80; },
    get currentRow() { return snapshot.screen?.currentRow || 0; },
  };
  const session = {
    get connected() { return !!snapshot.session?.connected; },
    get name() { return snapshot.session?.name || ''; },
    get hostname() { return snapshot.session?.hostname || ''; },
    get username() { return snapshot.session?.username || ''; },
    sleep,
    startLog: path => call('session.startLog', [String(path)]),
    stopLog: () => call('session.stopLog'),
    disconnect: () => call('session.disconnect'),
  };
  const dialog = Object.fromEntries(['confirm', 'prompt', 'alert', 'form', 'select', 'radio', 'checkbox'].map(name => [name, (...args) => call('dialog.' + name, args)]));
  const progress = Object.fromEntries(['start', 'step', 'set', 'done'].map(name => [name, (...args) => notify('progress.' + name, args)]));
  globalThis.nct = Object.freeze({ version: '1', screen: Object.freeze(screen), session: Object.freeze(session), dialog: Object.freeze(dialog), progress: Object.freeze(progress), sleep, log: value => notify('log', [String(value ?? '')]) });
  globalThis.console = Object.freeze({ log: (...values) => notify('log', [values.map(String).join(' ')]) });
  return function deliver(encoded) {
    const reply = JSON.parse(encoded);
    if (reply.snapshot) snapshot = reply.snapshot;
    const request = pending.get(String(reply.id));
    if (!request) throw new Error('Unknown script reply');
    pending.delete(String(reply.id));
    if (reply.ok) request.resolve(reply.result); else request.reject(new Error(reply.error || 'Script operation failed'));
  };
})()
