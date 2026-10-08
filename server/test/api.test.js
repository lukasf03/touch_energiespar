// Ende-zu-Ende-Tests gegen den laufenden Server.
// Start mit: npm test   (benoetigt nur Node und express)

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const PANEL_TOKEN = 'test-token-mindestens-16-zeichen';
const ADMIN_PASSWORD = 'test-kennwort';

let child;
let baseUrl;
let dataDir;

function waitForExit(proc) {
  return new Promise((resolve) => proc.once('exit', resolve));
}

before(async () => {
  dataDir = mkdtempSync(join(tmpdir(), 'wdp-test-'));

  child = startServer({ PORT: '0' });

  // Der Server schreibt seinen Port in die erste Zeile.
  const port = await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`Server startete nicht rechtzeitig. stderr: ${stderr}`)),
      15000,
    );
    let buffer = '';
    child.stdout.on('data', (chunk) => {
      buffer += chunk.toString();
      const match = buffer.match(/Port (\d+)/);
      if (match) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`Server endete mit Code ${code}. stderr: ${stderr}`));
    });
  });

  baseUrl = `http://127.0.0.1:${port}`;
});

let stderr = '';

function startServer(extraEnv) {
  const proc = spawn(process.execPath, [join(here, '..', 'src', 'index.js')], {
    env: {
      ...process.env,
      // node:sqlite ist als eingebautes Modul noch als experimentell markiert
      // und wuerde sonst eine Warnung auf stderr schreiben.
      NODE_NO_WARNINGS: '1',
      DB_FILE: join(dataDir, 'test.db'),
      PANEL_TOKEN,
      ADMIN_PASSWORD,
      ...extraEnv,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  proc.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  return proc;
}

after(async () => {
  if (child && child.exitCode === null) {
    child.kill('SIGTERM');
    await waitForExit(child);
  }
  if (dataDir) rmSync(dataDir, { recursive: true, force: true });
});

const panelHeaders = { Authorization: `Bearer ${PANEL_TOKEN}` };

async function adminLogin() {
  const response = await fetch(`${baseUrl}/api/v1/admin/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: ADMIN_PASSWORD }),
  });
  assert.equal(response.status, 200);
  const cookie = response.headers.getSetCookie()[0].split(';')[0];
  return { Cookie: cookie, 'Content-Type': 'application/json' };
}

// --- Panel-Schnittstelle --------------------------------------------------

test('Zeitplan ohne Token wird abgewiesen', async () => {
  const response = await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`);
  assert.equal(response.status, 401);
});

test('Zeitplan mit falschem Token wird abgewiesen', async () => {
  const response = await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, {
    headers: { Authorization: 'Bearer falsch' },
  });
  assert.equal(response.status, 401);
});

test('Panel meldet sich beim ersten Abruf selbst an und bekommt Standardwerte', async () => {
  const response = await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.panelId, 'pfarrheim');
  assert.equal(body.sleepTime, '22:00');
  assert.equal(body.wakeTime, '06:00');
  assert.equal(body.mode, 'Combined');
  assert.equal(body.enabled, true);
  assert.equal(body.keepAwakeUntil, null);
  assert.equal(body.command.name, 'none');
});

test('Ungueltige Panel-Kennung wird abgewiesen', async () => {
  const response = await fetch(`${baseUrl}/api/v1/panels/${encodeURIComponent('BÖSE/../etc')}/schedule`, {
    headers: panelHeaders,
  });
  assert.equal(response.status, 400);
});

test('Statusmeldung wird gespeichert und in der Uebersicht gezeigt', async () => {
  const post = await fetch(`${baseUrl}/api/v1/panels/pfarrheim/heartbeat`, {
    method: 'POST',
    headers: { ...panelHeaders, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      agentVersion: '1.1.0',
      displayState: 'on',
      insideSleepWindow: false,
      effectiveMode: 'Combined',
      consecutiveWakeFailures: 0,
      unbekanntesFeld: 'wird verworfen',
    }),
  });
  assert.equal(post.status, 204);

  const headers = await adminLogin();
  const list = await (await fetch(`${baseUrl}/api/v1/admin/panels`, { headers })).json();
  const panel = list.panels.find((entry) => entry.id === 'pfarrheim');
  assert.equal(panel.heartbeat.displayState, 'on');
  assert.equal(panel.heartbeat.effectiveMode, 'Combined');
  assert.ok(panel.heartbeatAt, 'Zeitpunkt der Meldung fehlt');
  assert.equal('unbekanntesFeld' in panel.heartbeat, false, 'unbekannte Felder muessen verworfen werden');
});

// --- Weboberflaeche -------------------------------------------------------

test('Uebersicht ohne Anmeldung wird abgewiesen', async () => {
  const response = await fetch(`${baseUrl}/api/v1/admin/panels`);
  assert.equal(response.status, 401);
});

test('Anmeldung mit falschem Kennwort wird abgewiesen', async () => {
  const response = await fetch(`${baseUrl}/api/v1/admin/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: 'falsch' }),
  });
  assert.equal(response.status, 401);
});

test('Zeiten aendern und das Panel holt die neuen Werte', async () => {
  const headers = await adminLogin();
  const put = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ sleepTime: '21:30', wakeTime: '07:15', mode: 'DisplayOnly' }),
  });
  assert.equal(put.status, 200);

  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(fetched.sleepTime, '21:30');
  assert.equal(fetched.wakeTime, '07:15');
  assert.equal(fetched.mode, 'DisplayOnly');
});

test('Ungueltige Uhrzeit wird abgewiesen', async () => {
  const headers = await adminLogin();
  for (const value of ['25:00', '7:5', '22:60', 'abc', '']) {
    const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({ sleepTime: value }),
    });
    assert.equal(response.status, 400, `"${value}" haette abgewiesen werden muessen`);
  }
});

test('Identische Schlafens- und Weckzeit wird abgewiesen', async () => {
  const headers = await adminLogin();
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ sleepTime: '07:15' }),
  });
  assert.equal(response.status, 400);
});

test('Unbekannter Modus wird abgewiesen', async () => {
  const headers = await adminLogin();
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ mode: 'Herunterfahren' }),
  });
  assert.equal(response.status, 400);
});

test('Uebersteuerung weiter als 30 Tage in der Zukunft wird abgewiesen', async () => {
  const headers = await adminLogin();
  const far = new Date(Date.now() + 60 * 24 * 60 * 60 * 1000).toISOString();
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ keepAwakeUntil: far }),
  });
  assert.equal(response.status, 400);
});

test('Uebersteuerung setzen und wieder entfernen', async () => {
  const headers = await adminLogin();
  const until = new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString();

  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ keepAwakeUntil: until }),
  });
  let fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(new Date(fetched.keepAwakeUntil).toISOString(), until);

  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ keepAwakeUntil: null }),
  });
  fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(fetched.keepAwakeUntil, null);
});

test('Befehl erhaelt eine Kennung und bleibt bis zum Ersetzen stabil', async () => {
  const headers = await adminLogin();
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim/command`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ name: 'wake-now' }),
  });
  assert.equal(response.status, 200);

  const first = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(first.command.name, 'wake-now');
  assert.match(first.command.id, /^[A-Za-z0-9._-]{1,64}$/);

  // Mehrfaches Abholen liefert dieselbe Kennung: der Agent fuehrt sie genau
  // einmal aus, erkennbar an der Kennung.
  const second = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(second.command.id, first.command.id);

  // Ein neuer Befehl bekommt eine neue Kennung.
  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim/command`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ name: 'sleep-now' }),
  });
  const third = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(third.command.name, 'sleep-now');
  assert.notEqual(third.command.id, first.command.id);
});

test('Unbekannter Befehl wird abgewiesen', async () => {
  const headers = await adminLogin();
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim/command`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ name: 'shutdown' }),
  });
  assert.equal(response.status, 400);
});

test('Zeitplan abschalten wird uebertragen', async () => {
  const headers = await adminLogin();
  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ enabled: false }),
  });
  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(fetched.enabled, false);
});

test('Unbekanntes Panel liefert 404 in der Oberflaeche', async () => {
  const headers = await adminLogin();
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/gibtesnicht`, { headers });
  assert.equal(response.status, 404);
});

test('Daten bleiben nach einem Neustart erhalten', async () => {
  const before = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();

  child.kill('SIGTERM');
  await waitForExit(child);

  child = startServer({ PORT: new URL(baseUrl).port });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Neustart zu langsam. stderr: ${stderr}`)), 15000);
    child.stdout.on('data', (chunk) => {
      if (chunk.toString().includes('Port')) {
        clearTimeout(timer);
        resolve();
      }
    });
  });

  const after = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(after.sleepTime, before.sleepTime);
  assert.equal(after.wakeTime, before.wakeTime);
  assert.equal(after.enabled, before.enabled);
});
