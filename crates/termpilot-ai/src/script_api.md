# TermPilot JavaScript automation

Scripts run in an isolated QuickJS process controlled by Rust. No Node.js or Python is required. Filesystem, network, process and module APIs are unavailable. Use `nct` for terminal operations. Source may contain bare statements, `async function main()`, or an invoked async function.

- `await nct.screen.send(text)` sends raw input; `sendLine(text)` sends input followed by Enter.
- `await nct.screen.getText(startLine?, endLine?)` reads at most 300 retained lines.
- `await nct.screen.waitForText(text, timeoutMs?)` matches literal output.
- `waitForRegex(pattern, timeoutMs?)` accepts a RegExp or pattern string.
- `waitFor(pattern, timeoutMs?)`, `waitForAny(patterns, timeoutMs?)`, `waitForPrompt(timeoutMs?)` wait for subsequent output.
- `await nct.sleep(ms)` and `nct.session.sleep(ms)` delay execution.
- `nct.session.connected/name/hostname/username` describe the bound connection.
- `await nct.session.disconnect()` closes only that connection.
- `nct.log(text)` and `nct.progress.start/step/set/done` report activity.
- `await nct.dialog.confirm/prompt/alert/form/select/radio/checkbox(...)` requests native user input.

Pausing takes effect at the next host operation. Stopping terminates the script worker; commands already delivered to the terminal may still run and must be checked. Another script or AI shell job cannot occupy the same terminal concurrently.

`onConnect` runs global targets first, then matching dynamic group paths, then the ordered host queue. `host_connect_scripts_set` replaces the explicit queue; inherited scripts remain. `onOutput` matches a bounded terminal-output buffer with Rust regex syntax, debounces output for 100 ms, and limits automatic triggers to 16 per minute per terminal. Scripts still pass through the configured permission mode. `screen.clear()` sends the same terminal escape input used by the baseline.

Current limitations: `session.startLog/stopLog` are not implemented; JavaScript-only regex constructs such as lookbehind are not accepted for automatic output triggers. Screen metadata refreshes when `getText()` is called. This reference does not claim complete Netcatty script compatibility.
