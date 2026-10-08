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
  assert.deepEqual(body.schedule.Monday, { On: '18:00', Off: '22:00' });
  assert.deepEqual(body.schedule.Friday, { On: '17:00', Off: '02:00' });
  assert.deepEqual(body.schedule.Sunday, { On: '16:00', Off: '23:00' });
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

const VOLLER_PLAN = {
  Monday: { On: '18:00', Off: '22:00' },
  Tuesday: { On: '18:00', Off: '22:00' },
  Wednesday: { On: '18:00', Off: '22:00' },
  Thursday: { On: '18:00', Off: '22:00' },
  Friday: { On: '17:00', Off: '02:00' },
  Saturday: { On: '17:00', Off: '02:00' },
  Sunday: { On: '16:00', Off: '23:00' },
};

test('Wochenplan aendern und das Panel holt die neuen Werte', async () => {
  const headers = await adminLogin();
  const put = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({
      schedule: { ...VOLLER_PLAN, Monday: { On: '19:30', Off: '23:15' }, Tuesday: null },
      mode: 'DisplayOnly',
    }),
  });
  assert.equal(put.status, 200);

  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.deepEqual(fetched.schedule.Monday, { On: '19:30', Off: '23:15' });
  assert.equal('Tuesday' in fetched.schedule, false, 'abgewaehlter Tag darf nicht im Plan stehen');
  assert.deepEqual(fetched.schedule.Friday, { On: '17:00', Off: '02:00' });
  assert.equal(fetched.mode, 'DisplayOnly');
});

test('Fenster ueber Mitternacht bleibt erhalten', async () => {
  const headers = await adminLogin();
  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ schedule: VOLLER_PLAN }),
  });
  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.deepEqual(fetched.schedule.Saturday, { On: '17:00', Off: '02:00' });
});

test('Ungueltige Uhrzeit im Wochenplan wird abgewiesen', async () => {
  const headers = await adminLogin();
  for (const value of ['25:00', '7:5', '22:60', 'abc', '']) {
    const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({ schedule: { ...VOLLER_PLAN, Monday: { On: value, Off: '22:00' } } }),
    });
    assert.equal(response.status, 400, `"${value}" haette abgewiesen werden muessen`);
  }
});

test('Wochenplan ganz ohne Fenster wird abgewiesen', async () => {
  const headers = await adminLogin();
  const leer = Object.fromEntries(Object.keys(VOLLER_PLAN).map((d) => [d, null]));
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ schedule: leer }),
  });
  assert.equal(response.status, 400);
});

test('Tag mit gleicher An- und Aus-Zeit gilt als aus', async () => {
  const headers = await adminLogin();
  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ schedule: { ...VOLLER_PLAN, Wednesday: { On: '18:00', Off: '18:00' } } }),
  });
  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal('Wednesday' in fetched.schedule, false);
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

// --- Fernwartung ----------------------------------------------------------

test('Fernwartungs-Kennung wird uebernommen und angezeigt', async () => {
  await fetch(`${baseUrl}/api/v1/panels/pfarrheim/heartbeat`, {
    method: 'POST',
    headers: { ...panelHeaders, 'Content-Type': 'application/json' },
    body: JSON.stringify({ remoteId: '123456789', displayState: 'on' }),
  });

  const headers = await adminLogin();
  const panel = await (await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, { headers })).json();
  assert.equal(panel.heartbeat.remoteId, '123456789');
});

test('Unbrauchbare Fernwartungs-Kennung wird verworfen', async () => {
  const headers = await adminLogin();
  for (const value of ['<script>alert(1)</script>', 'ab', 'x'.repeat(40), '12 34']) {
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/heartbeat`, {
      method: 'POST',
      headers: { ...panelHeaders, 'Content-Type': 'application/json' },
      body: JSON.stringify({ remoteId: value }),
    });
    const panel = await (await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, { headers })).json();
    assert.equal(panel.heartbeat.remoteId, null, `"${value}" haette verworfen werden muessen`);
  }
});

test('Wartungsfenster haelt das Panel befristet wach', async () => {
  const headers = await adminLogin();
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim/maintenance`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ minutes: 60 }),
  });
  assert.equal(response.status, 200);

  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  const minutes = (new Date(fetched.keepAwakeUntil).getTime() - Date.now()) / 60000;
  assert.ok(minutes > 58 && minutes <= 60, `Fenster liegt bei ${minutes} Minuten`);
});

test('Wartungsfenster ohne Angabe dauert 60 Minuten', async () => {
  const headers = await adminLogin();
  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim/maintenance`, {
    method: 'POST',
    headers,
    body: JSON.stringify({}),
  });
  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  const minutes = (new Date(fetched.keepAwakeUntil).getTime() - Date.now()) / 60000;
  assert.ok(minutes > 58 && minutes <= 60);
});

test('Unsinnige Wartungsdauer wird abgewiesen', async () => {
  const headers = await adminLogin();
  for (const minutes of [0, 4, 481, -60, 1.5, 'lange', null]) {
    const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim/maintenance`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ minutes }),
    });
    // null faellt auf den Standardwert 60 zurueck, alles andere ist ungueltig.
    const expected = minutes === null ? 200 : 400;
    assert.equal(response.status, expected, `minutes=${minutes} ergab ${response.status}`);
  }
});

test('Wartungsfenster laesst sich beenden', async () => {
  const headers = await adminLogin();
  await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ keepAwakeUntil: null }),
  });
  const fetched = await (
    await fetch(`${baseUrl}/api/v1/panels/pfarrheim/schedule`, { headers: panelHeaders })
  ).json();
  assert.equal(fetched.keepAwakeUntil, null);
});

test('Wartungsfenster ohne Anmeldung wird abgewiesen', async () => {
  const response = await fetch(`${baseUrl}/api/v1/admin/panels/pfarrheim/maintenance`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ minutes: 60 }),
  });
  assert.equal(response.status, 401);
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
  assert.deepEqual(after.schedule, before.schedule);
  assert.equal(after.enabled, before.enabled);
});
