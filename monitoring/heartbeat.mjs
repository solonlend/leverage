export function parseHeartbeat(line, nowSeconds = Date.now() / 1000) {
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z) heartbeat scanned=\d+ active=\d+ unhealthy=\d+ failed=0$/.exec(line);
  if (!match) return null;
  const updatedAt = Date.parse(match[1]) / 1000;
  if (!Number.isFinite(updatedAt) || !Number.isFinite(nowSeconds) || updatedAt > nowSeconds || nowSeconds - updatedAt > 60) return null;
  if (new Date(updatedAt * 1000).toISOString() !== match[1]) return null;
  return { updatedAt: Math.floor(updatedAt) };
}

import { createInterface } from 'node:readline';
import { writeFile, rename, unlink } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { resolve, relative, dirname, isAbsolute, sep } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

// Exported for offline tests; the CLI confines configured output to monitoring/.
export async function writeHeartbeat(file, heartbeat) {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(heartbeat)}\n`, { mode: 0o600, flag: 'wx' });
    await rename(temporary, file);
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

async function main() {
  const file = process.env.HEARTBEAT_FILE;
  if (!file || process.stdin.isTTY) throw new Error('invalid configuration');
  const root = dirname(fileURLToPath(import.meta.url));
  const child = relative(root, resolve(file));
  if (!child || child === '..' || child.startsWith(`..${sep}`) || isAbsolute(child)) throw new Error('invalid path');
  await runHeartbeatStream(process.stdin, file);
}

// Injectable streams/writer let offline tests cover errors and pending-write shutdown.
export async function runHeartbeatStream(input, file, { signals = process, write = writeHeartbeat } = {}) {
  const lines = createInterface({ input, crlfDelay: Infinity });
  let stopped = false;
  const stop = () => {
    stopped = true;
    lines.close();
    input.destroy();
  };
  signals.on('SIGINT', stop);
  signals.on('SIGTERM', stop);
  const iterator = lines[Symbol.asyncIterator]();
  try {
    await write(file, { updatedAt: 0 });
    if (!stopped) {
      for await (const line of iterator) {
        if (stopped) break;
        const heartbeat = parseHeartbeat(line);
        if (!heartbeat) continue;
        await write(file, heartbeat);
      }
    }
  } finally {
    stop();
    try {
      // Awaited loop writes finish before revocation, so a pending write cannot revive it.
      await write(file, { updatedAt: 0 });
    } finally {
      signals.removeListener('SIGINT', stop);
      signals.removeListener('SIGTERM', stop);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    process.stderr.write('Heartbeat sidecar failed; check HEARTBEAT_FILE and input.\n');
    process.exitCode = 1;
  });
}
