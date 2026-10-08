// Datenhaltung ueber das in Node eingebaute SQLite (node:sqlite, ab Node 22.5).
// Kein externes Modul, keine Migrationen ausser dem Schema unten.

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

import { WEEKDAYS, DEFAULT_SCHEDULE } from './validate.js';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS panels (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL DEFAULT '',
  schedule          TEXT NOT NULL,
  mode              TEXT NOT NULL DEFAULT 'Combined',
  enabled           INTEGER NOT NULL DEFAULT 1,
  keep_awake_until  TEXT,
  command_name      TEXT,
  command_id        TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS heartbeats (
  panel_id    TEXT PRIMARY KEY,
  received_at TEXT NOT NULL,
  payload     TEXT NOT NULL
);
`;

let db;

export function openDatabase(file) {
  mkdirSync(dirname(file), { recursive: true });
  db = new DatabaseSync(file);
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec('PRAGMA foreign_keys = ON;');
  db.exec(SCHEMA);
  migrateToWeeklySchedule();
  return db;
}

// Aeltere Datenbanken hielten ein einzelnes Schlaf-Fenster (sleep_time bis
// wake_time). Daraus wird ein Wochenplan: das Panel war genau umgekehrt an,
// naemlich von wake_time bis sleep_time, und das an jedem Tag gleich.
function migrateToWeeklySchedule() {
  const columns = db.prepare('PRAGMA table_info(panels)').all().map((c) => c.name);
  if (columns.includes('schedule') && !columns.includes('sleep_time')) return;

  if (!columns.includes('schedule')) {
    db.exec(`ALTER TABLE panels ADD COLUMN schedule TEXT NOT NULL DEFAULT ''`);
  }

  const rows = db.prepare(`SELECT id, sleep_time, wake_time FROM panels WHERE schedule = '' OR schedule IS NULL`).all();
  const update = db.prepare('UPDATE panels SET schedule = ? WHERE id = ?');
  for (const row of rows) {
    const schedule = {};
    for (const day of WEEKDAYS) {
      schedule[day] = { On: row.wake_time ?? '06:00', Off: row.sleep_time ?? '22:00' };
    }
    update.run(JSON.stringify(schedule), row.id);
  }
  if (rows.length > 0) {
    console.log(`Wochenplan fuer ${rows.length} Panel(s) aus den alten Zeiten uebernommen.`);
  }
}

const nowIso = () => new Date().toISOString();

export function listPanels() {
  const rows = db
    .prepare(
      `SELECT p.*, h.received_at AS heartbeat_at, h.payload AS heartbeat_payload
         FROM panels p
         LEFT JOIN heartbeats h ON h.panel_id = p.id
        ORDER BY p.id`,
    )
    .all();
  return rows.map(toPanel);
}

export function getPanel(id) {
  const row = db
    .prepare(
      `SELECT p.*, h.received_at AS heartbeat_at, h.payload AS heartbeat_payload
         FROM panels p
         LEFT JOIN heartbeats h ON h.panel_id = p.id
        WHERE p.id = ?`,
    )
    .get(id);
  return row ? toPanel(row) : null;
}

// Panels melden sich beim ersten Abruf selbst an, damit ein neues Geraet nur
// Adresse und Token braucht.
export function ensurePanel(id) {
  const existing = getPanel(id);
  if (existing) return existing;

  const ts = nowIso();
  db.prepare(
    `INSERT INTO panels (id, name, schedule, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
  ).run(id, id, JSON.stringify(DEFAULT_SCHEDULE), ts, ts);
  return getPanel(id);
}

export function updatePanel(id, changes) {
  const columns = {
    name: 'name',
    schedule: 'schedule',
    mode: 'mode',
    enabled: 'enabled',
    keepAwakeUntil: 'keep_awake_until',
  };

  const sets = [];
  const values = [];
  for (const [key, column] of Object.entries(columns)) {
    if (!(key in changes)) continue;
    sets.push(`${column} = ?`);
    const value = changes[key];
    if (key === 'enabled') values.push(value ? 1 : 0);
    else if (key === 'schedule') values.push(JSON.stringify(value));
    else values.push(value === null ? null : String(value));
  }
  if (sets.length === 0) return getPanel(id);

  sets.push('updated_at = ?');
  values.push(nowIso(), id);
  db.prepare(`UPDATE panels SET ${sets.join(', ')} WHERE id = ?`).run(...values);
  return getPanel(id);
}

export function setCommand(id, name) {
  // Die Kennung macht den Befehl eindeutig: das Panel fuehrt jede Kennung
  // genau einmal aus, auch wenn es sie mehrfach abholt.
  const commandId = name === 'none' ? null : `${Date.now().toString(36)}-${randomSuffix()}`;
  db.prepare(
    `UPDATE panels SET command_name = ?, command_id = ?, updated_at = ? WHERE id = ?`,
  ).run(name === 'none' ? null : name, commandId, nowIso(), id);
  return getPanel(id);
}

export function saveHeartbeat(id, payload) {
  db.prepare(
    `INSERT INTO heartbeats (panel_id, received_at, payload) VALUES (?, ?, ?)
       ON CONFLICT(panel_id) DO UPDATE SET received_at = excluded.received_at, payload = excluded.payload`,
  ).run(id, nowIso(), JSON.stringify(payload));
}

function randomSuffix() {
  return Math.random().toString(36).slice(2, 10);
}

function toPanel(row) {
  let heartbeat = null;
  if (row.heartbeat_payload) {
    try {
      heartbeat = JSON.parse(row.heartbeat_payload);
    } catch {
      heartbeat = null;
    }
  }
  let schedule;
  try {
    schedule = JSON.parse(row.schedule);
  } catch {
    // Unlesbarer Wochenplan darf das Panel nicht lahmlegen.
    schedule = DEFAULT_SCHEDULE;
  }

  return {
    id: row.id,
    name: row.name,
    schedule,
    mode: row.mode,
    enabled: row.enabled === 1,
    keepAwakeUntil: row.keep_awake_until,
    command: row.command_id ? { id: row.command_id, name: row.command_name } : { name: 'none' },
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    heartbeatAt: row.heartbeat_at ?? null,
    heartbeat,
  };
}
