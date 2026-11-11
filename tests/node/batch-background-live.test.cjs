'use strict';
// Run only against the disposable OpenSSH fixture, never a production host.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const engine = process.env.TERMPILOT_TEST_ENGINE || path.resolve(__dirname, '../../target/release/termpilot-engine');
const port = Number(process.env.TERMPILOT_BACKGROUND_FIXTURE_PORT || 0);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const final = frames => frames.find(frame => frame.stage === 'finished');

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'TermPilot-background-live-'));
  async function run({elevation = 'none', body = ':', timeout = 0, historyJobId = '', action = '', killClient = false, password} = {}) {
    const frames = [];
    let stderr = '';
    const child = spawn(engine, ['batch'], {stdio: ['pipe', 'pipe', 'pipe']});
    child.stderr.on('data', data => stderr += data);
    readline.createInterface({input: child.stdout}).on('line', line => {
      const frame = JSON.parse(line);
      frames.push(frame);
      if (killClient && frame.stage === 'execute') child.kill('SIGKILL');
    });
    child.stdin.write(JSON.stringify({
      job: {kind: 'execute', executionMode: 'background', stepTimeout: timeout, connectTimeout: 10, script: {body}},
      targets: [{id: 'live', config: {
        hostname: '127.0.0.1', port, username: 'fixture', authentication: 'password',
        password: 'fixture-password', elevationPassword: password ?? (elevation === 'su' ? 'root-password' : 'fixture-password'),
        batchElevation: elevation, autoAcceptHostKeys: true, knownHostsFile: path.join(directory, 'known_hosts'),
        batchCredentialId: 'fixture-credential-reference'
      }}],
      historyDirectory: path.join(directory, 'history'), historyJobId, backgroundAction: action
    }) + '\n');
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { child.kill('SIGKILL'); reject(Error('Worker timeout: ' + stderr)); }, 25000);
      child.on('error', error => { clearTimeout(timer); reject(error); });
      child.on('exit', code => {
        clearTimeout(timer);
        if (!killClient && code !== 0) reject(Error(`Worker exited ${code}: ${stderr}\n${JSON.stringify(frames)}`));
        else resolve();
      });
    });
    return frames;
  }
  async function done(historyJobId, elevation) {
    const deadline = Date.now() + 20000;
    let frames;
    while (Date.now() < deadline) {
      frames = await run({historyJobId, elevation, action: 'status'});
      if (!['pending', 'running'].includes(final(frames)?.status)) return frames;
      await pause(100);
    }
    throw Error('Remote task did not finish: ' + JSON.stringify(frames));
  }
  return {run, done, close: () => fs.rmSync(directory, {recursive: true, force: true})};
}

test('Linux OpenSSH: detached tasks survive client SIGKILL under login, sudo and su; history restores logs and cleanup', {skip: !port, timeout: 120000}, async () => {
  const f = fixture();
  try {
    for (const elevation of ['none', 'sudo', 'su']) {
      const submitted = await f.run({
        elevation, killClient: true,
        body: 'printf "user="; id -un; printf "started\\n"; touch "$REMOTE_WORK_DIR/temporary"; sleep 2; printf "finished 中文\\n"'
      });
      const start = submitted.find(frame => frame.type === 'batchStarted');
      assert.ok(submitted.some(frame => frame.stage === 'execute' && frame.status === 'running'), JSON.stringify(submitted));
      const receiptText = fs.readFileSync(path.join(start.reportDirectory, 'background.json'), 'utf8');
      assert.ok(!receiptText.includes('fixture-password') && !receiptText.includes('root-password'));
      const complete = await f.done(start.jobId, elevation);
      assert.equal(final(complete).status, 'success', JSON.stringify(complete));
      assert.equal(final(complete).exitCode, 0);
      assert.equal(final(complete).cleanupStatus, 'success');
      const output = complete.find(frame => frame.stage === 'execute');
      assert.match(output.stdout, elevation === 'none' ? /user=fixture/ : /user=root/);
      assert.match(output.stdout, /finished 中文/);
      assert.match(output.remoteLogDirectory, elevation === 'none' ? /^\/home\/fixture\// : /^\/root\//);
      const downloaded = await f.run({historyJobId: start.jobId, elevation, action: 'logs'});
      assert.equal(fs.readFileSync(downloaded.find(frame => frame.stepId === 'stdout').localPath, 'utf8'), output.stdout);
      // Inspect through a new task: temporary path is gone, log record is retained.
      const check = await f.run({elevation, body: `test ! -e '${output.remoteWorkDirectory}' && test -f '${output.remoteLogDirectory}/state.json'`});
      assert.equal(final(await f.done(check.find(frame => frame.type === 'batchStarted').jobId, elevation)).status, 'success');
    }
  } finally { f.close(); }
});

test('Linux OpenSSH: full-size scripts cross sudo and su PTYs without argument or terminal line limits', {skip: !port, timeout: 60000}, async () => {
  const f = fixture();
  try {
    const ending = '\nprintf full-size';
    const body = '#' + require('node:crypto').randomBytes(100000).toString('base64').slice(0, 128 * 1024 - ending.length - 1) + ending;
    assert.equal(Buffer.byteLength(body), 128 * 1024);
    for (const elevation of ['sudo', 'su']) {
      const submitted = await f.run({elevation, body});
      const id = submitted.find(frame => frame.type === 'batchStarted').jobId;
      const complete = await f.done(id, elevation);
      assert.equal(final(complete).status, 'success', JSON.stringify(complete));
      assert.equal(complete.find(frame => frame.stage === 'execute').stdout, 'full-size');
      assert.equal(final(complete).cleanupStatus, 'success');
    }
  } finally { f.close(); }
});

test('Linux OpenSSH: remote deadlines and explicit cancellation clean up; wrong reconnect credentials never replay', {skip: !port, timeout: 90000}, async () => {
  const f = fixture();
  try {
    let submitted = await f.run({elevation: 'sudo', timeout: 1, body: 'sleep 30'});
    let id = submitted.find(frame => frame.type === 'batchStarted').jobId;
    let complete = await f.done(id, 'sudo');
    assert.equal(final(complete).status, 'failed', JSON.stringify(complete));
    assert.equal(final(complete).timedOut, true);
    assert.equal(final(complete).cleanupStatus, 'success');
    submitted = await f.run({elevation: 'su', body: 'sleep 30'});
    id = submitted.find(frame => frame.type === 'batchStarted').jobId;
    const denied = await f.run({historyJobId: id, elevation: 'su', action: 'status', password: 'wrong'});
    assert.equal(final(denied).status, 'unknown');
    assert.equal(final(denied).remoteStateUnknown, true);
    await f.run({historyJobId: id, elevation: 'su', action: 'cancel'});
    complete = await f.done(id, 'su');
    assert.equal(final(complete).status, 'cancelled', JSON.stringify(complete));
    assert.equal(final(complete).cleanupStatus, 'success');
    assert.equal(final(complete).remoteStateUnknown, false);
  } finally { f.close(); }
});
