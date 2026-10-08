// Datenhaltung ueber das in Node eingebaute SQLite (node:sqlite, ab Node 22.5).
// Kein externes Modul, keine Migrationen ausser dem Schema unten.

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS panels (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL DEFAULT '',
  sleep_time        TEXT NOT NULL DEFAULT '22:00',
  wake_time         TEXT NOT NULL DEFAULT '06:00',
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
  return db;
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
    `INSERT INTO panels (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)`,
  ).run(id, id, ts, ts);
  return getPanel(id);
}

export function updatePanel(id, changes) {
  const columns = {
    name: 'name',
    sleepTime: 'sleep_time',
    wakeTime: 'wake_time',
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
    values.push(key === 'enabled' ? (value ? 1 : 0) : value === null ? null : String(value));
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
  return {
    id: row.id,
    name: row.name,
    sleepTime: row.sleep_time,
    wakeTime: row.wake_time,
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
