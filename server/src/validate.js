// Pruefung aller Eingaben. Die Panel-Antwort steuert, wann ein Rechner
// schlafen geht - sie darf darum nur feste, geprueft gueltige Werte enthalten.

export const MODES = ['Combined', 'DisplayOnly', 'SuspendOnly'];
export const COMMANDS = ['none', 'sleep-now', 'wake-now'];

const TIME_PATTERN = /^([01]\d|2[0-3]):([0-5]\d)$/;
const PANEL_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,62}$/;

export class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ValidationError';
    this.statusCode = 400;
  }
}

export function assertPanelId(value) {
  const id = String(value ?? '').trim().toLowerCase();
  if (!PANEL_ID_PATTERN.test(id)) {
    throw new ValidationError(
      'Panel-Kennung muss aus 1 bis 63 Zeichen bestehen: Kleinbuchstaben, Ziffern, Punkt, Bindestrich, Unterstrich.',
    );
  }
  return id;
}

export function assertTime(value, field) {
  const text = String(value ?? '').trim();
  if (!TIME_PATTERN.test(text)) {
    throw new ValidationError(`${field} muss im Format HH:mm vorliegen, zum Beispiel 22:00.`);
  }
  return text;
}

export function assertMode(value) {
  const text = String(value ?? '').trim();
  if (!MODES.includes(text)) {
    throw new ValidationError(`Modus muss einer von ${MODES.join(', ')} sein.`);
  }
  return text;
}

export function assertCommand(value) {
  const text = String(value ?? '').trim();
  if (!COMMANDS.includes(text)) {
    throw new ValidationError(`Befehl muss einer von ${COMMANDS.join(', ')} sein.`);
  }
  return text;
}

export function assertOptionalTimestamp(value, field) {
  if (value === null || value === undefined || value === '') return null;
  const date = new Date(String(value));
  if (Number.isNaN(date.getTime())) {
    throw new ValidationError(`${field} ist kein gueltiger Zeitpunkt.`);
  }
  const limit = Date.now() + 30 * 24 * 60 * 60 * 1000;
  if (date.getTime() > limit) {
    throw new ValidationError(`${field} darf hoechstens 30 Tage in der Zukunft liegen.`);
  }
  return date.toISOString();
}

// Wartungsfenster: lang genug fuer eine echte Sitzung, kurz genug, dass ein
// vergessenes Fenster nicht die halbe Woche Strom kostet.
export function assertMaintenanceMinutes(value) {
  const minutes = Number(value);
  if (!Number.isInteger(minutes) || minutes < 5 || minutes > 480) {
    throw new ValidationError('Wartungsdauer muss eine ganze Zahl zwischen 5 und 480 Minuten sein.');
  }
  return minutes;
}

export function assertName(value) {
  const text = String(value ?? '').trim();
  if (text.length > 80) throw new ValidationError('Name darf hoechstens 80 Zeichen lang sein.');
  return text;
}

// Zeitplan-Aenderungen aus der Weboberflaeche.
export function parseScheduleInput(body) {
  if (typeof body !== 'object' || body === null) {
    throw new ValidationError('Es wurden keine Daten uebermittelt.');
  }

  const changes = {};
  if ('name' in body) changes.name = assertName(body.name);
  if ('sleepTime' in body) changes.sleepTime = assertTime(body.sleepTime, 'Schlafenszeit');
  if ('wakeTime' in body) changes.wakeTime = assertTime(body.wakeTime, 'Weckzeit');
  if ('mode' in body) changes.mode = assertMode(body.mode);
  if ('enabled' in body) changes.enabled = Boolean(body.enabled);
  if ('keepAwakeUntil' in body) {
    changes.keepAwakeUntil = assertOptionalTimestamp(body.keepAwakeUntil, 'Wach bleiben bis');
  }

  const sleep = changes.sleepTime;
  const wake = changes.wakeTime;
  if (sleep && wake && sleep === wake) {
    throw new ValidationError('Schlafenszeit und Weckzeit duerfen nicht identisch sein.');
  }

  if (Object.keys(changes).length === 0) {
    throw new ValidationError('Es wurde kein aenderbares Feld uebermittelt.');
  }
  return changes;
}

// Statusmeldung des Panels. Gespeichert wird nur, was hier aufgefuehrt ist;
// alles andere wird verworfen, damit ein Panel die Datenbank nicht fuellen kann.
export function parseHeartbeat(body) {
  if (typeof body !== 'object' || body === null) return {};

  const text = (value, max = 200) =>
    value === null || value === undefined ? null : String(value).slice(0, max);

  // Die Fernwartungs-Kennung wird in der Oberflaeche angezeigt, darum nur
  // unbedenkliche Zeichen zulassen.
  const remoteId = String(body.remoteId ?? '');
  const safeRemoteId = /^[A-Za-z0-9_-]{4,32}$/.test(remoteId) ? remoteId : null;

  return {
    remoteId: safeRemoteId,
    agentVersion: text(body.agentVersion, 32),
    computerName: text(body.computerName, 64),
    reportedAtUtc: text(body.reportedAtUtc, 40),
    configuredSleepTime: text(body.configuredSleepTime, 8),
    configuredWakeTime: text(body.configuredWakeTime, 8),
    configuredMode: text(body.configuredMode, 20),
    effectiveMode: text(body.effectiveMode, 20),
    enabled: Boolean(body.enabled),
    insideSleepWindow: Boolean(body.insideSleepWindow),
    displayState: text(body.displayState, 16),
    lastWakeUtc: text(body.lastWakeUtc, 40),
    lastWakeDelayMinutes: Number.isFinite(Number(body.lastWakeDelayMinutes))
      ? Number(body.lastWakeDelayMinutes)
      : null,
    consecutiveWakeFailures: Number.isFinite(Number(body.consecutiveWakeFailures))
      ? Number(body.consecutiveWakeFailures)
      : 0,
    fallbackReason: text(body.fallbackReason, 300),
    appliedCommandId: text(body.appliedCommandId, 64),
    sleepStates: Array.isArray(body.sleepStates)
      ? body.sleepStates.slice(0, 8).map((entry) => text(entry, 8))
      : [],
  };
}
