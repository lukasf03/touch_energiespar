// Steuerungsserver fuer die Energiesteuerung von Wand-Touchpanels.
//
// Zwei getrennte Zugaenge:
//   /api/v1/panels/...  Panels, angemeldet mit PANEL_TOKEN (Bearer)
//   /api/v1/admin/...   Weboberflaeche, angemeldet mit ADMIN_PASSWORD
//
// Die Panel-Antwort wird vom Agenten strikt geprueft; hier wird ebenfalls
// nichts gespeichert, was nicht vorher validiert wurde.

import express from 'express';
import { randomBytes, timingSafeEqual, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { openDatabase, listPanels, getPanel, ensurePanel, updatePanel, setCommand, saveHeartbeat } from './db.js';
import {
  ValidationError,
  assertPanelId,
  assertCommand,
  assertMaintenanceMinutes,
  parseScheduleInput,
  parseHeartbeat,
} from './validate.js';

const here = dirname(fileURLToPath(import.meta.url));

const PORT = Number(process.env.PORT ?? 8080);
const DB_FILE = process.env.DB_FILE ?? '/data/walldisplay.db';
const PANEL_TOKEN = process.env.PANEL_TOKEN ?? '';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD ?? '';
const TRUST_PROXY = process.env.TRUST_PROXY === '1';

if (!PANEL_TOKEN || PANEL_TOKEN.length < 16) {
  console.error('PANEL_TOKEN fehlt oder ist kuerzer als 16 Zeichen. Abbruch.');
  process.exit(1);
}
if (!ADMIN_PASSWORD || ADMIN_PASSWORD.length < 8) {
  console.error('ADMIN_PASSWORD fehlt oder ist kuerzer als 8 Zeichen. Abbruch.');
  process.exit(1);
}

openDatabase(DB_FILE);

const app = express();
if (TRUST_PROXY) app.set('trust proxy', 1);
app.disable('x-powered-by');
app.use(express.json({ limit: '16kb' }));

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-Frame-Options', 'DENY');
  next();
});

// ------------------------------------------------------------------ Anmeldung

function constantTimeEquals(a, b) {
  const left = createHash('sha256').update(String(a)).digest();
  const right = createHash('sha256').update(String(b)).digest();
  return timingSafeEqual(left, right);
}

// Einfache Anmeldesperre: nach zu vielen Fehlversuchen pro Adresse eine Pause.
const failedAttempts = new Map();
const MAX_ATTEMPTS = 10;
const LOCK_MS = 15 * 60 * 1000;

function isLocked(ip) {
  const entry = failedAttempts.get(ip);
  if (!entry) return false;
  if (Date.now() - entry.first > LOCK_MS) {
    failedAttempts.delete(ip);
    return false;
  }
  return entry.count >= MAX_ATTEMPTS;
}

function noteFailure(ip) {
  const entry = failedAttempts.get(ip) ?? { count: 0, first: Date.now() };
  entry.count += 1;
  failedAttempts.set(ip, entry);
}

function requirePanelToken(req, res, next) {
  const header = String(req.headers.authorization ?? '');
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token || !constantTimeEquals(token, PANEL_TOKEN)) {
    noteFailure(req.ip);
    return res.status(401).json({ error: 'Nicht angemeldet.' });
  }
  next();
}

const sessions = new Map();
const SESSION_MS = 12 * 60 * 60 * 1000;

function createSession() {
  const id = randomBytes(32).toString('hex');
  sessions.set(id, { expires: Date.now() + SESSION_MS });
  return id;
}

function requireAdmin(req, res, next) {
  const cookie = String(req.headers.cookie ?? '')
    .split(';')
    .map((part) => part.trim())
    .find((part) => part.startsWith('wdp_session='));
  const id = cookie ? cookie.slice('wdp_session='.length) : '';
  const session = sessions.get(id);
  if (!session || session.expires < Date.now()) {
    if (session) sessions.delete(id);
    return res.status(401).json({ error: 'Nicht angemeldet.' });
  }
  next();
}

setInterval(() => {
  const now = Date.now();
  for (const [id, session] of sessions) if (session.expires < now) sessions.delete(id);
}, 60 * 60 * 1000).unref();

// ------------------------------------------------------------- Panel-Zugriffe

app.get('/api/v1/panels/:panelId/schedule', requirePanelToken, (req, res) => {
  const id = assertPanelId(req.params.panelId);
  const panel = ensurePanel(id);

  res.json({
    version: 2,
    panelId: panel.id,
    enabled: panel.enabled,
    schedule: panel.schedule,
    mode: panel.mode,
    keepAwakeUntil: panel.keepAwakeUntil,
    command: panel.command,
    updatedAt: panel.updatedAt,
  });
});

app.post('/api/v1/panels/:panelId/heartbeat', requirePanelToken, (req, res) => {
  const id = assertPanelId(req.params.panelId);
  ensurePanel(id);
  saveHeartbeat(id, parseHeartbeat(req.body));
  res.status(204).end();
});

// ------------------------------------------------------------- Admin-Zugriffe

app.post('/api/v1/admin/login', (req, res) => {
  if (isLocked(req.ip)) {
    return res.status(429).json({ error: 'Zu viele Fehlversuche. Bitte spaeter erneut versuchen.' });
  }
  const password = String(req.body?.password ?? '');
  if (!password || !constantTimeEquals(password, ADMIN_PASSWORD)) {
    noteFailure(req.ip);
    return res.status(401).json({ error: 'Falsches Kennwort.' });
  }
  failedAttempts.delete(req.ip);

  const id = createSession();
  const secure = TRUST_PROXY ? ' Secure;' : '';
  res.setHeader(
    'Set-Cookie',
    `wdp_session=${id}; HttpOnly;${secure} SameSite=Strict; Path=/; Max-Age=${SESSION_MS / 1000}`,
  );
  res.json({ ok: true });
});

app.post('/api/v1/admin/logout', requireAdmin, (req, res) => {
  res.setHeader('Set-Cookie', 'wdp_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
  res.json({ ok: true });
});

app.get('/api/v1/admin/panels', requireAdmin, (req, res) => {
  res.json({ panels: listPanels() });
});

app.get('/api/v1/admin/panels/:panelId', requireAdmin, (req, res) => {
  const panel = getPanel(assertPanelId(req.params.panelId));
  if (!panel) return res.status(404).json({ error: 'Panel nicht gefunden.' });
  res.json(panel);
});

app.put('/api/v1/admin/panels/:panelId', requireAdmin, (req, res) => {
  const id = assertPanelId(req.params.panelId);
  if (!getPanel(id)) return res.status(404).json({ error: 'Panel nicht gefunden.' });

  res.json(updatePanel(id, parseScheduleInput(req.body)));
});

app.post('/api/v1/admin/panels/:panelId/command', requireAdmin, (req, res) => {
  const id = assertPanelId(req.params.panelId);
  if (!getPanel(id)) return res.status(404).json({ error: 'Panel nicht gefunden.' });
  res.json(setCommand(id, assertCommand(req.body?.name)));
});

// Wartungsfenster: haelt das Panel fuer eine begrenzte Zeit wach, damit man
// sich per Fernwartung aufschalten kann. Danach gilt wieder der Zeitplan.
//
// Das wirkt nur, solange das Panel ueberhaupt erreichbar ist. Liegt es bereits
// im Energiesparmodus, kann es nichts abrufen - dann greift das Fenster erst,
// wenn es durch seinen Aufwachzeitgeber von selbst hochkommt.
app.post('/api/v1/admin/panels/:panelId/maintenance', requireAdmin, (req, res) => {
  const id = assertPanelId(req.params.panelId);
  if (!getPanel(id)) return res.status(404).json({ error: 'Panel nicht gefunden.' });

  const minutes = assertMaintenanceMinutes(req.body?.minutes ?? 60);
  const until = new Date(Date.now() + minutes * 60 * 1000).toISOString();
  res.json(updatePanel(id, { keepAwakeUntil: until }));
});

// ------------------------------------------------------------------- Statisch

app.get('/healthz', (req, res) => res.json({ ok: true }));
app.use(express.static(join(here, '..', 'public'), { index: 'index.html', maxAge: '5m' }));

// -------------------------------------------------------------- Fehlerausgabe

app.use((err, req, res, next) => {
  if (err instanceof ValidationError || err?.name === 'ValidationError') {
    return res.status(err.statusCode ?? 400).json({ error: err.message });
  }
  if (err?.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'Ungueltiges JSON.' });
  }
  console.error('Unerwarteter Fehler:', err);
  res.status(500).json({ error: 'Interner Fehler.' });
});

const server = app.listen(PORT, () => {
  // Den tatsaechlich gebundenen Port melden, nicht den gewuenschten: bei
  // PORT=0 waehlt das Betriebssystem einen freien Port.
  console.log(`WallDisplay-Server laeuft auf Port ${server.address().port}, Datenbank ${DB_FILE}`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    console.log(`${signal} empfangen, Server wird beendet.`);
    server.close(() => process.exit(0));
  });
}
