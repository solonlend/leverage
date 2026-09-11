import { appendFile } from 'node:fs/promises';

/** Credentials are supplied by the caller from environment variables. Never log errors. */
export function createNotifier({ logFile, token, chatId, fetchImpl = globalThis.fetch,
  stdout = line => process.stdout.write(line), now = Date.now } = {}) {
  const encode = (level, msg) => JSON.stringify({ time: new Date(now()).toISOString(), level, msg }) + '\n';
  const writeStdout = line => { try { stdout(line); return true; } catch { return false; } };
  const diagnostic = async msg => {
    const line = encode('warn', msg);
    writeStdout(line);
    if (logFile) { try { await appendFile(logFile, line, { mode: 0o600 }); } catch { /* No raw error output. */ } }
  };
  return async function notify(level, msg) {
    const line = encode(level, msg);
    let delivered = writeStdout(line);
    if (logFile) {
      try { await appendFile(logFile, line, { mode: 0o600 }); }
      catch { delivered = false; await diagnostic('Log write failed'); }
    }
    if (token && chatId) {
      try {
        const response = await fetchImpl(`https://api.telegram.org/bot${token}/sendMessage`, {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ chat_id: chatId, text: `SOLON MONITOR [${level}] ${msg}` }),
          signal: AbortSignal.timeout(10_000),
        });
        if (!response.ok || !(await response.json()).ok) throw new Error('delivery failed');
      } catch { delivered = false; await diagnostic('Telegram delivery failed'); }
    }
    return delivered;
  };
}

/** Cooldown is recorded only after successful delivery; escalation bypasses it. */
export function createAlertGate({ notify, cooldownMs, now = Date.now }) {
  const last = new Map();
  const rank = { info: 0, warn: 1, critical: 2 };
  const alert = async (key, level, msg) => {
    const previous = last.get(key);
    const time = now();
    if (previous && rank[level] <= rank[previous.level] && time - previous.time < cooldownMs) return true;
    let delivered;
    try { delivered = await notify(level, msg); } catch { return false; }
    if (delivered) last.set(key, { level, time });
    return Boolean(delivered);
  };
  alert.clear = key => last.delete(key);
  return alert;
}
