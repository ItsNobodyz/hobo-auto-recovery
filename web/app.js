'use strict';

const panel      = document.getElementById('scanner-panel');
const rows       = [document.getElementById('plate-0'), document.getElementById('plate-1')];
const keybindLbl = document.getElementById('keybind-label');
const versionLbl = document.getElementById('version-label');
const handle     = document.getElementById('resize-handle');
const dragArea   = document.querySelector('.scanner-header');

// ── State ─────────────────────────────────────────────────────────────────────

var inCursorMode = false;
var savedKeybind = 'F6';

// ── NUI message handler ───────────────────────────────────────────────────────

window.addEventListener('message', function(event) {
  var data = event.data;
  if (!data || !data.action) return;

  switch (data.action) {
    case 'show':
      savedKeybind = data.keybind || 'F6';
      panel.classList.remove('hidden');
      keybindLbl.textContent = '[' + savedKeybind + '] CURSOR';
      if (data.version) versionLbl.textContent = 'HOBO Auto-Recovery v' + data.version;
      inCursorMode = false;
      f6HoldStart  = null;
      restoreSize();
      restorePosition();
      break;

    case 'cursorMode':
      keybindLbl.textContent = '[F6] LOCK';
      inCursorMode = true;
      break;

    case 'scanMode':
      keybindLbl.textContent = '[' + savedKeybind + '] CURSOR';
      inCursorMode = false;
      f6HoldStart  = null;
      break;

    case 'hide':
      panel.classList.add('hidden');
      inCursorMode = false;
      f6HoldStart  = null;
      rows.forEach(function(r) { resetRow(r); });
      break;

    // v1.4.3: lightweight visibility toggle for the on-foot gate. Does NOT
    // change scanner state on the Lua side — operator stays in scan mode,
    // panel just disappears while they're out of the driver seat. Rows are
    // cleared so when they re-enter the vehicle they don't see stale plates.
    case 'scanner:hide':
      panel.classList.add('hidden');
      rows.forEach(function(r) { resetRow(r); });
      break;

    case 'scanner:show':
      panel.classList.remove('hidden');
      break;

    case 'updatePlates':
      var plates = data.plates || [];
      rows.forEach(function(r, i) {
        var p = plates[i];
        if (p) setRow(r, p.plate, p.status);
        else   resetRow(r);
      });
      // v1.4.4: header countdown for the duty grace period. Lua side sends
      // gracePeriod (bool) + graceLeft (seconds) on every scan tick. Show the
      // pulsing CAL badge while grace is active, hide it the moment it ends.
      var calTimer = document.getElementById('cal-timer');
      if (calTimer) {
        if (data.gracePeriod) {
          calTimer.textContent = 'CAL ' + Math.max(0, data.graceLeft || 0) + 's';
          calTimer.classList.remove('hidden');
        } else {
          calTimer.classList.add('hidden');
        }
      }
      break;
  }
});

// ── Plate row helpers ─────────────────────────────────────────────────────────

function setRow(row, plateText, status) {
  var plateEl  = row.querySelector('.plate-text');
  var statusEl = row.querySelector('.status-badge');
  var arrowEl  = row.querySelector('.arrow');

  plateEl.textContent = plateText || '——————';
  row.classList.remove('scanning', 'lockon', 'calibrating');

  if (status === 'lockon') {
    row.classList.add('lockon');
    statusEl.textContent = '🔒 REPO';
    arrowEl.textContent  = '▶';
  } else if (status === 'calibrating') {
    row.classList.add('calibrating');
    statusEl.textContent = 'CAL';
    arrowEl.textContent  = '▶';
  } else if (status === 'scanning') {
    row.classList.add('scanning');
    statusEl.textContent = 'CLEAR';
    arrowEl.textContent  = '▶';
  } else {
    statusEl.textContent = '—';
    arrowEl.textContent  = ' ';
  }
}

function resetRow(row) {
  row.querySelector('.plate-text').textContent   = '——————';
  row.querySelector('.status-badge').textContent = '—';
  row.querySelector('.arrow').textContent        = ' ';
  row.classList.remove('scanning', 'lockon', 'calibrating');
}

// ── Size persistence ──────────────────────────────────────────────────────────

function restoreSize() {
  var w = localStorage.getItem('hobo_scanner_w');
  if (w) {
    panel.style.width    = w;
    panel.style.minWidth = 'unset';
  }
}

function saveSize() {
  if (panel.style.width) {
    localStorage.setItem('hobo_scanner_w', panel.style.width);
  }
}

// ── Position persistence ──────────────────────────────────────────────────────

function restorePosition() {
  var x = localStorage.getItem('hobo_scanner_x');
  var y = localStorage.getItem('hobo_scanner_y');
  if (x && y) {
    panel.style.left      = x;
    panel.style.top       = y;
    panel.style.right     = 'unset';
    panel.style.transform = 'none';
  }
}

function savePosition() {
  if (panel.style.left) {
    localStorage.setItem('hobo_scanner_x', panel.style.left);
    localStorage.setItem('hobo_scanner_y', panel.style.top);
  }
}

// ── Drag-to-move ──────────────────────────────────────────────────────────────

var dragging = false;
var dragStartX, dragStartY, panelStartX, panelStartY;

dragArea.addEventListener('mousedown', function(e) {
  if (e.target === handle || handle.contains(e.target)) return;
  dragging    = true;
  dragStartX  = e.clientX;
  dragStartY  = e.clientY;
  var rect    = panel.getBoundingClientRect();
  panelStartX = rect.left;
  panelStartY = rect.top;
  panel.style.left      = panelStartX + 'px';
  panel.style.top       = panelStartY + 'px';
  panel.style.right     = 'unset';
  panel.style.transform = 'none';
  e.preventDefault();
});

// ── Drag-to-resize ────────────────────────────────────────────────────────────

var resizing = false;
var resizeStartX, resizeStartW;

handle.addEventListener('mousedown', function(e) {
  resizing     = true;
  resizeStartX = e.clientX;
  resizeStartW = panel.offsetWidth;
  e.preventDefault();
  fetch('https://hobo-auto-recovery/setFocus', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ active: true })
  });
});

// ── Shared mousemove / mouseup ────────────────────────────────────────────────

document.addEventListener('mousemove', function(e) {
  if (dragging) {
    panel.style.left = (panelStartX + e.clientX - dragStartX) + 'px';
    panel.style.top  = (panelStartY + e.clientY - dragStartY) + 'px';
  }
  if (resizing) {
    var newW = Math.max(180, resizeStartW + (e.clientX - resizeStartX));
    panel.style.width    = newW + 'px';
    panel.style.minWidth = 'unset';
  }
});

document.addEventListener('mouseup', function() {
  if (dragging) {
    dragging = false;
    savePosition();
  }
  if (resizing) {
    resizing = false;
    saveSize();
    // Only release NUI focus if we're not in cursor mode (temporary resize grab)
    if (!inCursorMode) {
      fetch('https://hobo-auto-recovery/setFocus', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ active: false })
      });
    }
  }
});

// ── F6 hold detection in cursor mode ─────────────────────────────────────────
// When SetNuiFocus(true, true) is active, RegisterKeyMapping commands don't fire
// in Lua. NUI owns the keyboard, so we handle F6 here and call back to Lua.

var f6HoldStart = null;

document.addEventListener('keydown', function(e) {
  if (e.code === 'F6' && inCursorMode && f6HoldStart === null) {
    f6HoldStart = Date.now();
    e.preventDefault();
  }
});

document.addEventListener('keyup', function(e) {
  if (e.code === 'F6' && inCursorMode) {
    var held   = f6HoldStart !== null ? Date.now() - f6HoldStart : 0;
    f6HoldStart = null;
    var action = (held >= 3000) ? 'scannerOff' : 'cursorToggle';
    fetch('https://hobo-auto-recovery/' + action, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({})
    });
    e.preventDefault();
  }
});
