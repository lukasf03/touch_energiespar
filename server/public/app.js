// Weboberflaeche der Wandpanel-Steuerung. Bewusst ohne Framework: die Seite
// besteht aus einer Liste und einem Formular je Panel.

const $ = (selector, root = document) => root.querySelector(selector);

const loginSection = $('#login');
const panelsSection = $('#panels');
const panelList = $('#panel-list');
const messageBox = $('#message');
const logoutButton = $('#logout');

let refreshTimer = null;

function showMessage(text, kind = 'info') {
  messageBox.textContent = text;
  messageBox.className = kind;
  messageBox.hidden = !text;
  if (text && kind !== 'error') {
    setTimeout(() => {
      if (messageBox.textContent === text) messageBox.hidden = true;
    }, 4000);
  }
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: 'same-origin',
    headers: options.body ? { 'Content-Type': 'application/json' } : {},
    ...options,
  });

  if (response.status === 401) {
    showLogin();
    throw new Error('Bitte erneut anmelden.');
  }
  if (!response.ok) {
    let detail = `Fehler ${response.status}`;
    try {
      detail = (await response.json()).error ?? detail;
    } catch {
      /* Antwort ohne JSON */
    }
    throw new Error(detail);
  }
  return response.status === 204 ? null : response.json();
}

function showLogin() {
  loginSection.hidden = false;
  panelsSection.hidden = true;
  logoutButton.hidden = true;
  if (refreshTimer) {
    clearInterval(refreshTimer);
    refreshTimer = null;
  }
}

function showPanels() {
  loginSection.hidden = true;
  panelsSection.hidden = false;
  logoutButton.hidden = false;
  if (!refreshTimer) refreshTimer = setInterval(() => loadPanels(true), 30000);
}

// --- Darstellung ----------------------------------------------------------

function formatSeen(iso) {
  if (!iso) return 'noch nie';
  const minutes = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (minutes < 1) return 'gerade eben';
  if (minutes < 60) return `vor ${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `vor ${hours} h`;
  return new Date(iso).toLocaleString('de-DE');
}

function isOnline(iso) {
  // Das Panel meldet sich alle 5 Minuten. Im Standby meldet es sich nicht,
  // darum ist "still" nicht gleich "offline".
  return iso ? Date.now() - new Date(iso).getTime() < 12 * 60 * 1000 : false;
}

function toLocalInputValue(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function renderPanel(panel) {
  const node = $('#panel-template').content.firstElementChild.cloneNode(true);
  node.dataset.panelId = panel.id;

  const beat = panel.heartbeat ?? {};
  $('.panel-name', node).textContent = panel.name || panel.id;

  const badge = $('.state', node);
  const online = isOnline(panel.heartbeatAt);
  const sleeping = beat.insideSleepWindow === true;
  badge.textContent = online ? (sleeping ? 'Nachtbetrieb' : 'Tagbetrieb') : 'keine Meldung';
  badge.className = `badge state ${online ? (sleeping ? 'night' : 'day') : 'stale'}`;

  $('.seen', node).textContent = formatSeen(panel.heartbeatAt);
  $('.display', node).textContent = beat.displayState ?? '–';
  $('.effective', node).textContent = beat.effectiveMode ?? '–';
  $('.failures', node).textContent = beat.consecutiveWakeFailures ?? '–';

  if (beat.fallbackReason) {
    const warn = $('.fallback', node);
    warn.textContent = `Rückstufung aktiv: ${beat.fallbackReason}`;
    warn.hidden = false;
  }

  const form = $('.schedule', node);
  form.name.value = panel.name ?? '';
  form.sleepTime.value = panel.sleepTime;
  form.wakeTime.value = panel.wakeTime;
  form.mode.value = panel.mode;
  form.enabled.checked = panel.enabled;
  form.keepAwakeUntil.value = toLocalInputValue(panel.keepAwakeUntil);

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const keepAwake = form.keepAwakeUntil.value;
    try {
      await api(`/api/v1/admin/panels/${encodeURIComponent(panel.id)}`, {
        method: 'PUT',
        body: JSON.stringify({
          name: form.name.value,
          sleepTime: form.sleepTime.value,
          wakeTime: form.wakeTime.value,
          mode: form.mode.value,
          enabled: form.enabled.checked,
          keepAwakeUntil: keepAwake ? new Date(keepAwake).toISOString() : null,
        }),
      });
      showMessage('Gespeichert. Das Panel übernimmt es beim nächsten Abruf.', 'ok');
      await loadPanels(true);
    } catch (error) {
      showMessage(error.message, 'error');
    }
  });

  for (const button of node.querySelectorAll('[data-command]')) {
    button.addEventListener('click', async () => {
      try {
        await api(`/api/v1/admin/panels/${encodeURIComponent(panel.id)}/command`, {
          method: 'POST',
          body: JSON.stringify({ name: button.dataset.command }),
        });
        showMessage('Befehl vorgemerkt, das Panel führt ihn beim nächsten Abruf aus.', 'ok');
        await loadPanels(true);
      } catch (error) {
        showMessage(error.message, 'error');
      }
    });
  }

  return node;
}

async function loadPanels(quiet = false) {
  try {
    const { panels } = await api('/api/v1/admin/panels');
    // Formulare, in denen gerade getippt wird, nicht unter den Fingern ersetzen.
    if (quiet && panelList.contains(document.activeElement)) return;

    panelList.replaceChildren();
    if (panels.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'hint';
      empty.textContent = 'Noch kein Panel angemeldet.';
      panelList.append(empty);
      return;
    }
    for (const panel of panels) panelList.append(renderPanel(panel));
  } catch (error) {
    if (!quiet) showMessage(error.message, 'error');
  }
}

// --- Start ----------------------------------------------------------------

$('#login-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    await api('/api/v1/admin/login', {
      method: 'POST',
      body: JSON.stringify({ password: $('#password').value }),
    });
    $('#password').value = '';
    showMessage('');
    showPanels();
    await loadPanels();
  } catch (error) {
    showMessage(error.message, 'error');
  }
});

logoutButton.addEventListener('click', async () => {
  try {
    await api('/api/v1/admin/logout', { method: 'POST' });
  } catch {
    /* Abmelden darf nicht scheitern */
  }
  showLogin();
});

// Beim Laden pruefen, ob noch eine gueltige Sitzung besteht.
(async () => {
  try {
    await api('/api/v1/admin/panels');
    showPanels();
    await loadPanels();
  } catch {
    showLogin();
  }
})();
