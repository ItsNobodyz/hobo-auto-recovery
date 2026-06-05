'use strict';

/* ─────────────────────────────────────────────────────────────────────────────
   tablet.js — /towtab DRN-style ALPR tablet (v1.4.1)
   Owns the #tablet DOM only. Ignores any NUI action it doesn't recognize.
   Audio callouts (fl/fr/rl/rr.wav) fire ONLY on confirmed repo hits.

   v1.4.1: plate-card rendering by GTA plate-index, clickable hit list +
   active orders → info modal, single-list Active Repo Orders driven by
   marker snapshot, draggable + resizable tablet with localStorage geometry.
   ───────────────────────────────────────────────────────────────────────────── */

const RES = (window.GetParentResourceName && GetParentResourceName()) || 'hobo-auto-recovery';
// v1.4.5: SCAN_HISTORY_MAX removed. state.scans is now the permanent per-plate
// log (one row per unique plate this NUI lifetime, dedup is forever via the
// state.seenPlates Set). Bounded organically by unique plates encountered.

// ── DOM refs ─────────────────────────────────────────────────────────────────

const tabletEl       = document.getElementById('tablet');
const userNameEl     = document.getElementById('tab-user-name');
const versionEl      = document.getElementById('stat-version');
const timeEl         = document.getElementById('stat-time');
const spottedEl      = document.getElementById('stat-spotted');         // v1.4.2: was transferred
const reposEl        = document.getElementById('stat-repos');           // v1.4.2: was processing
const hotCountEl     = document.getElementById('stat-hotlist-count');
const hotStatusEl    = document.getElementById('stat-hotlist-status');

const hitListEl      = document.getElementById('hit-list');
const scanTbody      = document.getElementById('scan-tbody');
const ordersList     = document.getElementById('orders-list');
const ordersCount    = document.getElementById('orders-count');
const searchInput    = document.getElementById('search-input');
const searchGo       = document.getElementById('search-go');
const searchResult   = document.getElementById('search-result');
const feedSidePlate    = document.getElementById('feed-side-plate');
const feedSidePlateSub = document.getElementById('feed-side-plate-sub');
const exitBtn        = document.getElementById('tab-exit');
const optNight       = document.getElementById('opt-night-theme');
const optCallouts    = document.getElementById('opt-callouts');
const optVolume      = document.getElementById('opt-volume');

const infoModal      = document.getElementById('info-modal');
const infoTitle      = document.getElementById('info-title');
const infoBody       = document.getElementById('info-body');
const infoCloseBtn   = document.getElementById('info-close');
const resizeHandle   = document.getElementById('tablet-resize-handle');

const alertOverlay   = document.getElementById('alert-overlay');
const alertTitle     = document.getElementById('alert-title');
const alertBody      = document.getElementById('alert-body');
const alertConfirm   = document.getElementById('alert-confirm');
const alertCancel    = document.getElementById('alert-cancel');

// ── State ────────────────────────────────────────────────────────────────────

const state = {
  scans: [],              // [{ plate, plateIndex, side, street, postal, driver, at, hit }]
  hits:  [],              // [{ plate, plateIndex, side, street, postal, driver, case, at }]
  orders: [],             // server snapshot rows (Active Repo Orders, marker-confirmed)
  filterCam: 'ALL',
  spotted: 0,             // distinct plates this operator has scanned this NUI lifetime
  // v1.4.4: persistent Set of plates the operator has scanned at any point this
  // NUI lifetime. Drives `spotted` so the counter only increments on first sight
  // and stays put on subsequent scans of the same plate ("once it's in the
  // system it shouldn't appear again"). Survives tablet close/reopen and duty
  // toggles — only resets when the script restarts (NUI reloads).
  seenPlates: new Set(),
  reposCompleted: 0,      // v1.4.2: server-wide count from snapshot
  selectedHitIdx: -1,     // v1.4.2: currently highlighted hit (for View Info / Clear Hit)
  calloutsEnabled: true,
};

// v1.4.5: SCAN_DEDUP_WINDOW_MS removed. Dedup is now permanent — same plate
// ALWAYS updates the existing row in place, never pushes a duplicate. The
// 5 s window was a holdover from v1.4.2 when the table was a sliding 100-row
// window; with the table now a permanent per-plate log, there's nothing for
// the window to gate.

// ── Audio callout (per-side) ─────────────────────────────────────────────────

const SIDE_SOUNDS = {
  'FRONT-LEFT':  new Audio('sounds/fl.wav'),
  'FRONT-RIGHT': new Audio('sounds/fr.wav'),
  'REAR-LEFT':   new Audio('sounds/rl.wav'),
  'REAR-RIGHT':  new Audio('sounds/rr.wav'),
};
Object.values(SIDE_SOUNDS).forEach(a => { a.preload = 'auto'; a.volume = 0.9; });

function setCalloutVolume(v) {
  const vol = Math.max(0, Math.min(1, v / 100));
  Object.values(SIDE_SOUNDS).forEach(a => { a.volume = vol; });
}

function playSideCallout(side) {
  if (!state.calloutsEnabled) return;
  const audio = SIDE_SOUNDS[side];
  if (!audio) return;
  audio.currentTime = 0;
  audio.play().catch(() => {});
}

// ── NUI bridge ───────────────────────────────────────────────────────────────

function postNui(event, body) {
  return fetch('https://' + RES + '/' + event, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  }).catch(() => {});
}

window.addEventListener('message', function(event) {
  const data = event.data;
  if (!data || !data.action) return;

  // Wrap every dispatch in try/catch so one bad render doesn't leave the
  // tablet in a half-open state (mouse focus grabbed by Lua, panel still
  // hidden, Esc handler can't find a visible element to close).
  try {
    switch (data.action) {
      case 'tablet:show':         showTablet(data); break;
      case 'tablet:hide':         hideTablet(); break;
      case 'tablet:appendScan':   onScans(data.scans); break;
      case 'tablet:appendHit':    onHit(data.hit); break;
      case 'tablet:hitCallout':   onHitCallout(data); break;
      case 'tablet:searchResult': renderSearchResult(data.result); break;
      case 'tablet:prompt':       showAlertPrompt(data); break;
      case 'tablet:promptCancel': hideAlertPrompt(); break;
      // v1.4.5: server-pushed Hot-List Count update. Cheap targeted write
      // so the count is current within ~50 ms of any CasePool change,
      // independent of the 10 s periodic snapshot refresh.
      case 'tablet:poolSizeUpdate':
        if (hotCountEl) hotCountEl.textContent = (data.size != null) ? data.size : '0';
        break;
      // any other action is for app.js (scanner) — ignore here
    }
  } catch (err) {
    console.error('[hobo-auto-recovery tablet] handler error for action',
                  data.action, err);
    // On show-path failure, force the panel visible anyway so the user can Esc.
    if (data.action === 'tablet:show') {
      tabletEl.classList.remove('hidden');
    }
  }
});

// ── Show / hide ──────────────────────────────────────────────────────────────

function showTablet(payload) {
  // Make the panel visible FIRST so a downstream render error can't leave us
  // with mouse focus grabbed but nothing on screen (Esc would be stuck).
  tabletEl.classList.remove('hidden');
  startClock();
  try { restoreGeometry(); } catch (e) { console.error('restoreGeometry', e); }
  try {
    applySnapshot(payload.snapshot || {});
    if (payload.version) versionEl.textContent = 'v' + payload.version;
    // v1.4.6: paint the accumulated scan log on open. onScans skipped DOM
    // updates while the tablet was hidden (state.scans was still updated),
    // so without this call the Setup tab's scan table would stay stale
    // until the next scan tick.
    renderScanTable();
  } catch (e) {
    console.error('applySnapshot', e);
  }
}

function hideTablet() {
  tabletEl.classList.add('hidden');
  closeInfoModal();
  stopClock();
  // v1.4.5: state.scans is now the permanent per-plate log (same lifecycle
  // as state.spotted / state.seenPlates added in v1.4.4). Only state.hits,
  // state.selectedHitIdx, and state.filterCam reset on hide — those are
  // genuinely view-scoped to a single tablet session.
  state.hits = [];
  state.selectedHitIdx = -1;
  state.filterCam = 'ALL';
  // (state.orders is repopulated from the next snapshot, so leave it.)
}

// ── Snapshot ─────────────────────────────────────────────────────────────────

function applySnapshot(snap) {
  state.orders = snap.activeOrders || [];
  state.reposCompleted = snap.reposCompleted || 0;
  userNameEl.textContent = snap.operatorName || '—';
  renderOrders();
  renderCounters();
  hotCountEl.textContent = (snap.poolSize != null) ? snap.poolSize : '0';
}

function renderCounters() {
  if (spottedEl) spottedEl.textContent = state.spotted;
  if (reposEl)   reposEl.textContent   = state.reposCompleted;
}

function renderOrders() {
  ordersCount.textContent = state.orders.length;
  if (!state.orders.length) {
    ordersList.innerHTML = '<div class="empty-state">No active repo orders.</div>';
    return;
  }
  // v1.4.3: in-transit cases get a CSS class + pill so operators viewing the
  // tablet see when a tow driver has /secure'd a marked vehicle. Field comes
  // from BuildTabletSnapshot's new `inTransitBy` copy of ActiveMarkers state.
  ordersList.innerHTML = state.orders.map((o, i) => {
    const inTransit = !!o.inTransitBy;
    const cls = 'case-row' + (inTransit ? ' in-transit' : '');
    return `
      <div class="${cls}" data-idx="${i}">
        ${renderPlateCard(o.plate, o.plateIndex, 'md')}
        <span class="meta">
          ${escapeHtml(o.ownerName || 'Unknown')} ·
          ${escapeHtml(o.color || '')} ${escapeHtml(o.model || '')} ·
          ${escapeHtml(o.reason || '')}
          ${inTransit ? '<span class="in-transit-pill">IN TRANSIT</span>' : ''}
          <br>
          <span class="loc">
            ${escapeHtml(o.street || 'Unknown location')}${o.postal ? ' · ' + escapeHtml(o.postal) : ''}
            · spotted ${formatAge(o.age)} ago by ${escapeHtml(o.placedBy || '—')}
          </span>
        </span>
        <span class="reward">$${(o.reward || 0).toLocaleString()}</span>
      </div>`;
  }).join('');
  ordersList.querySelectorAll('.case-row').forEach(row => {
    row.addEventListener('click', () => {
      const idx = +row.dataset.idx;
      openInfoModalFromOrder(state.orders[idx]);
    });
  });
}

function formatAge(s) {
  s = s || 0;
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm ' + (s % 60) + 's';
  return Math.floor(s / 3600) + 'h';
}

// ── Plate-card renderer ──────────────────────────────────────────────────────

function renderPlateCard(plate, plateIndex, size /* 'sm' | 'md' | 'lg' */) {
  const idx = (Number.isInteger(plateIndex) && plateIndex >= 0 && plateIndex <= 5) ? plateIndex : 0;
  return `<span class="plate-card plate-style-${idx} size-${size || 'md'}">${escapeHtml(plate)}</span>`;
}

// ── Scans (live feed) ────────────────────────────────────────────────────────

function onScans(scans) {
  if (!Array.isArray(scans)) return;
  const now = Date.now();
  let newCount = 0;

  for (const s of scans) {
    // v1.4.5: permanent dedup. Same plate ALWAYS updates the existing row
    // in place, no time window. User intent is "once per session" — each
    // unique plate appears exactly once in the table for the NUI lifetime.
    // state.seenPlates (added in v1.4.4) is the source-of-truth Set; this
    // dedup just keeps the table mirror consistent.
    const idx = state.scans.findIndex(x => x.plate === s.plate);
    if (idx >= 0) {
      state.scans[idx].side   = s.side   || state.scans[idx].side;
      state.scans[idx].street = s.street || state.scans[idx].street;
      state.scans[idx].postal = s.postal || state.scans[idx].postal;
      state.scans[idx].driver = s.driver || state.scans[idx].driver;
      state.scans[idx].at     = now;
      continue;
    }
    state.scans.unshift({
      plate:      s.plate,
      plateIndex: s.plateIndex || 0,
      side:       s.side,
      street:     s.street || '',
      postal:     s.postal || '',
      driver:     s.driver || '',
      at:         s.at || now,
      hit:        false,
    });
    // v1.4.4: counter increments only the FIRST time a plate is ever seen this
    // NUI lifetime, not every time it falls outside the 5 s in-place refresh
    // window. state.seenPlates is the source of truth — state.scans is just
    // the recent-history feed and gets trimmed/expired independently.
    if (!state.seenPlates.has(s.plate)) {
      state.seenPlates.add(s.plate);
      newCount++;
    }
  }
  // v1.4.5: SCAN_HISTORY_MAX cap removed. state.scans is permanent per-plate
  // now (one row per unique plate, no sliding window). Memory bounded by
  // unique plates encountered this NUI lifetime (~1000 plates ≈ 200 KB).

  state.spotted += newCount;
  renderCounters();

  // Feed the side-camera preview with the nearest plate
  if (scans[0] && feedSidePlate) {
    feedSidePlate.textContent    = scans[0].plate;
    feedSidePlateSub.textContent = formatLocation(scans[0]);
  }

  // v1.4.6: state.scans is always updated above so accumulated scans survive
  // the closed-tablet window (scanner.lua now pumps every tick regardless of
  // TabletOpen). Skip DOM render while the tablet is hidden — avoids wasted
  // layout work on an invisible table. showTablet calls renderScanTable() on
  // open to paint everything that accumulated while the tablet was closed.
  if (!tabletEl.classList.contains('hidden')) {
    renderScanTable();
  }
}

function formatLocation(s) {
  if (!s) return '';
  const street = s.street || '';
  const postal = s.postal || '';
  if (street && postal) return street + ' · ' + postal;
  return street || postal || '—';
}

function renderScanTable() {
  const rows = state.filterCam === 'ALL'
    ? state.scans
    : state.scans.filter(s => s.side === state.filterCam);

  // v1.4.2: explicit empty-state row so a filter that returns no matches
  // (or a fresh session with no scans yet) shows feedback instead of an
  // unchanged-looking table.
  if (!rows.length) {
    const msg = state.filterCam === 'ALL'
      ? 'No plates scanned yet.'
      : 'No scans on this camera.';
    scanTbody.innerHTML = `<tr><td colspan="4" class="empty-row">${msg}</td></tr>`;
    return;
  }

  scanTbody.innerHTML = rows.slice(0, 40).map(s => `
    <tr class="${s.hit ? 'hit' : ''}">
      <td class="col-img">${renderPlateCard(s.plate, s.plateIndex, 'sm')}</td>
      <td>${escapeHtml(s.plate)}</td>
      <td class="col-loc-cell" title="${escapeHtml(formatLocation(s))}">${escapeHtml(formatLocation(s))}</td>
      <td>${escapeHtml(s.driver || '—')}</td>
    </tr>
  `).join('');
}

// ── Hits (alert dialogue fired) + audio callout ─────────────────────────────

function onHit(hit) {
  if (!hit || !hit.plate) return;
  const plate = hit.plate.toUpperCase();

  // Mark the most recent matching scan as a hit (visual highlight)
  const idx = state.scans.findIndex(s => s.plate === plate);
  if (idx >= 0) state.scans[idx].hit = true;

  // Dedupe hit list — newest version wins. If the currently-selected plate
  // matches, keep the selection on the same plate (its index moves to 0).
  const wasSelected = state.selectedHitIdx >= 0
    && state.hits[state.selectedHitIdx]
    && state.hits[state.selectedHitIdx].plate === plate;

  state.hits = state.hits.filter(h => h.plate !== plate);
  state.hits.unshift({
    plate:      plate,
    plateIndex: hit.plateIndex || 0,
    side:       hit.side || '',
    street:     hit.street || '',
    postal:     hit.postal || '',
    driver:     hit.driver || '',
    case:       hit.case || {},
    at:         hit.at || Date.now(),
  });
  if (state.hits.length > 25) state.hits.length = 25;

  if (wasSelected) state.selectedHitIdx = 0;

  renderHitList();
  renderScanTable();
}

function onHitCallout(data) {
  const side = data.side || 'FRONT-RIGHT';
  playSideCallout(side);
}

function renderHitList() {
  if (!state.hits.length) {
    hitListEl.innerHTML = '';
    state.selectedHitIdx = -1;
    return;
  }
  // v1.4.2: click highlights only (selection model). View Info / Clear Hit
  // buttons act on the highlighted plate. No auto-modal on click.
  hitListEl.innerHTML = state.hits.map((h, i) =>
    `<li data-idx="${i}" class="${i === state.selectedHitIdx ? 'selected' : ''}" `
    + `title="${escapeHtml(h.side || '')}">${renderPlateCard(h.plate, h.plateIndex, 'md')}</li>`
  ).join('');
  hitListEl.querySelectorAll('li').forEach(li => {
    li.addEventListener('click', () => {
      state.selectedHitIdx = +li.dataset.idx;
      renderHitList();   // re-render to update .selected class
    });
  });
}

// ── Info modal ───────────────────────────────────────────────────────────────

function openInfoModalFromOrder(order) {
  if (!order) return;
  infoTitle.textContent = 'Repo Order — ' + order.plate;
  infoBody.innerHTML = renderInfoCard({
    plate:      order.plate,
    plateIndex: order.plateIndex,
    case: {
      ownerName:    order.ownerName,
      lienholder:   order.lienholder,
      vehicleMake:  order.model,
      vehicleColor: order.color,
      reason:       order.reason,
      amountOwed:   order.amountOwed,
      rewardAmount: order.reward,
    },
    street:     order.street,
    postal:     order.postal,
    driver:     order.placedBy,   // who spotted it
    spottedAge: order.age,
    coords:     order.coords,
    showGps:    true,
  });
  openInfoModal('Repo Order — ' + order.plate);
}

function openInfoModalFromHits(hits) {
  if (!hits || !hits.length) return;
  infoTitle.textContent = hits.length > 1
    ? ('Hit List — ' + hits.length + ' plates')
    : ('Plate Info — ' + hits[0].plate);
  infoBody.innerHTML = hits.map(h => renderInfoCard({
    plate:      h.plate,
    plateIndex: h.plateIndex,
    case:       h.case,
    street:     h.street,
    postal:     h.postal,
    driver:     h.driver,
    side:       h.side,
    showGps:    false,
  })).join('');
  openInfoModal(infoTitle.textContent);
}

function renderInfoCard(d) {
  const c = d.case || {};
  return `
    <div class="info-card">
      ${renderPlateCard(d.plate, d.plateIndex, 'lg')}
      <div class="info-row"><b>Owner</b><span>${escapeHtml(c.ownerName || c.owner_name || '—')}</span></div>
      <div class="info-row"><b>Lienholder</b><span>${escapeHtml(c.lienholder || '—')}</span></div>
      <div class="info-row"><b>Vehicle</b><span>${escapeHtml(c.vehicleColor || c.vehicle_color || '')} ${escapeHtml(c.vehicleMake || c.vehicle_make || '—')}</span></div>
      <div class="info-row"><b>Reason</b><span>${escapeHtml(c.reason || '—')}</span></div>
      <div class="info-row"><b>Amount owed</b><span>$${((c.amountOwed) || 0).toLocaleString()}</span></div>
      <div class="info-row"><b>Reward</b><span style="color:#6ce086">$${((c.rewardAmount || c.reward_amount) || 0).toLocaleString()}</span></div>
      <div class="info-row"><b>Location</b><span>${escapeHtml(d.street || 'Unknown')}${d.postal ? ' · ' + escapeHtml(d.postal) : ''}</span></div>
      ${d.driver ? `<div class="info-row"><b>${d.spottedAge != null ? 'Spotted by' : 'Driver'}</b><span>${escapeHtml(d.driver)}${d.spottedAge != null ? ' (' + formatAge(d.spottedAge) + ' ago)' : ''}</span></div>` : ''}
      ${d.side ? `<div class="info-row"><b>Camera</b><span>${escapeHtml(prettySide(d.side))}</span></div>` : ''}
      ${d.showGps && d.coords ? `
        <div class="info-actions">
          <button data-action="gps" data-x="${d.coords.x}" data-y="${d.coords.y}">Set GPS</button>
        </div>` : ''}
    </div>
  `;
}

function prettySide(side) {
  if (!side) return '—';
  return side.replace('-', ' ');
}

function openInfoModal(title) {
  infoTitle.textContent = title || 'Plate Info';
  infoModal.classList.remove('hidden');
  infoModal.setAttribute('aria-hidden', 'false');
}

function closeInfoModal() {
  infoModal.classList.add('hidden');
  infoModal.setAttribute('aria-hidden', 'true');
}

// Wire info-modal actions (event delegation — buttons are rendered dynamically)
infoModal.addEventListener('click', e => {
  if (e.target === infoModal.querySelector('.info-backdrop')) {
    closeInfoModal();
    return;
  }
  const btn = e.target.closest('button[data-action]');
  if (!btn) return;
  if (btn.dataset.action === 'gps') {
    const x = parseFloat(btn.dataset.x);
    const y = parseFloat(btn.dataset.y);
    if (Number.isFinite(x) && Number.isFinite(y)) {
      postNui('tabletGps', { x, y });
    }
  }
});
infoCloseBtn.addEventListener('click', closeInfoModal);

// ── Alert prompt (v1.4.2) ────────────────────────────────────────────────────
// Custom mouse-only confirm/cancel overlay so WASD keeps working while the
// player is driving when an alert pops. Lua passes a `token` so its waiting
// thread can match the response when this overlay posts back.
let currentAlertToken = null;

function showAlertPrompt(data) {
  currentAlertToken = data.token || null;
  alertTitle.textContent = data.title || 'Plate hit';
  alertBody.innerHTML    = renderAlertBody(data);
  alertConfirm.textContent = data.confirmLabel || 'Confirm';
  alertCancel.textContent  = data.cancelLabel  || 'Cancel';
  alertOverlay.classList.remove('hidden');
  alertOverlay.setAttribute('aria-hidden', 'false');
}

function hideAlertPrompt() {
  alertOverlay.classList.add('hidden');
  alertOverlay.setAttribute('aria-hidden', 'true');
  currentAlertToken = null;
}

function renderAlertBody(data) {
  // Accept a structured `fields` array OR a raw `content` string. Fields are
  // safer (escaped) and look better; content is a fallback for Lua callers
  // that just want to dump a markdown-ish string.
  if (Array.isArray(data.fields)) {
    return data.fields
      .map(f => `<div class="row"><b>${escapeHtml(f.label || '')}</b>${escapeHtml(f.value || '')}</div>`)
      .join('');
  }
  if (typeof data.content === 'string') {
    return escapeHtml(data.content).replace(/\n/g, '<br>');
  }
  return '';
}

function respondAlert(choice) {
  const token = currentAlertToken;
  hideAlertPrompt();
  postNui('tabletPromptResult', { token: token, choice: choice });
}

alertConfirm.addEventListener('click', () => respondAlert('confirm'));
alertCancel.addEventListener('click',  () => respondAlert('cancel'));

// ── Search result ───────────────────────────────────────────────────────────

function renderSearchResult(result) {
  if (!result) {
    searchResult.innerHTML = '<div class="search-empty">No response.</div>';
    return;
  }
  if (!result.hit) {
    searchResult.innerHTML = `
      <div class="search-clear">
        <h3>${escapeHtml(result.plate)} — CLEAR</h3>
        <div class="row">No active repo order for this plate.</div>
      </div>
    `;
    return;
  }
  const c = result.case || {};
  searchResult.innerHTML = `
    <div class="search-hit">
      <h3>🔒 ${escapeHtml(result.plate)} — REPO HIT</h3>
      <div class="row"><b>Owner:</b> ${escapeHtml(c.ownerName || '—')}</div>
      <div class="row"><b>Lienholder:</b> ${escapeHtml(c.lienholder || '—')}</div>
      <div class="row"><b>Vehicle:</b> ${escapeHtml(c.vehicleColor || '')} ${escapeHtml(c.vehicleMake || '')}</div>
      <div class="row"><b>Reason:</b> ${escapeHtml(c.reason || '—')}</div>
      <div class="row"><b>Amount owed:</b> $${((c.amountOwed) || 0).toLocaleString()}</div>
      <div class="row"><b>Reward:</b> $${((c.rewardAmount || c.reward_amount) || 0).toLocaleString()}</div>
      <div class="row" style="margin-top:8px; color: rgba(255,255,255,0.45); font-style: italic;">
        Information only — locate the vehicle and confirm via F6 scanner to accept the repo.
      </div>
    </div>
  `;
}

// ── Sidebar / cam-tab / exit wiring ──────────────────────────────────────────

document.querySelectorAll('.tab-sb-btn[data-pane]').forEach(btn => {
  btn.addEventListener('click', () => {
    const pane = btn.dataset.pane;
    if (pane === 'theme') {
      const isNight = tabletEl.classList.toggle('night');
      optNight.checked = isNight;
      return;
    }
    document.querySelectorAll('.tab-sb-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    document.querySelectorAll('.tab-pane').forEach(p => p.removeAttribute('data-active'));
    const target = document.querySelector('.tab-pane[data-pane="' + pane + '"]');
    if (target) target.setAttribute('data-active', '1');
  });
});

document.querySelectorAll('.cam-tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.cam-tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.filterCam = btn.dataset.cam || 'ALL';
    renderScanTable();
  });
});

exitBtn.addEventListener('click', () => postNui('tabletClose'));

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    if (!infoModal.classList.contains('hidden')) {
      closeInfoModal();
    } else if (!tabletEl.classList.contains('hidden')) {
      postNui('tabletClose');
    }
  }
});

searchGo.addEventListener('click', () => {
  const plate = (searchInput.value || '').toUpperCase().replace(/\s+/g, '');
  if (!plate) return;
  searchResult.innerHTML = '<div class="search-empty">Searching ' + escapeHtml(plate) + '…</div>';
  postNui('tabletSearch', { plate });
});
searchInput.addEventListener('keydown', e => {
  if (e.key === 'Enter') searchGo.click();
});

// v1.4.2: all three buttons now act on the highlighted plate (selectedHitIdx).
document.getElementById('hit-clear').addEventListener('click', () => {
  if (state.selectedHitIdx < 0 || !state.hits[state.selectedHitIdx]) {
    return toastInline('Click a plate first.');
  }
  state.hits.splice(state.selectedHitIdx, 1);
  state.selectedHitIdx = -1;
  renderHitList();
});
document.getElementById('hit-clear-all').addEventListener('click', () => {
  state.hits = [];
  state.selectedHitIdx = -1;
  renderHitList();
});
// "View Info" — open the info modal for the highlighted plate only.
document.getElementById('hit-view').addEventListener('click', () => {
  if (state.selectedHitIdx < 0 || !state.hits[state.selectedHitIdx]) {
    return toastInline('Click a plate first.');
  }
  openInfoModalFromHits([state.hits[state.selectedHitIdx]]);
});

// Small inline-toast for hit-list button guidance. Reuses the search-result
// empty-state styling so it doesn't need its own CSS surface.
function toastInline(msg) {
  if (searchResult) {
    searchResult.innerHTML = `<div class="search-empty">${escapeHtml(msg)}</div>`;
    // Bring the search pane into view so the toast is visible.
    const searchBtn = document.querySelector('.tab-sb-btn[data-pane="search"]');
    if (searchBtn) searchBtn.click();
  }
}

optNight.addEventListener('change', () => {
  tabletEl.classList.toggle('night', optNight.checked);
});
optCallouts.addEventListener('change', () => {
  state.calloutsEnabled = optCallouts.checked;
});
optVolume.addEventListener('input', () => {
  setCalloutVolume(+optVolume.value);
});

// ── Drag (titlebar) + Resize (corner handle) + localStorage geometry ─────────

const MIN_W = 900;
const MIN_H = 560;

function restoreGeometry() {
  try {
    const x = localStorage.getItem('hobo_tablet_x');
    const y = localStorage.getItem('hobo_tablet_y');
    const w = localStorage.getItem('hobo_tablet_w');
    const h = localStorage.getItem('hobo_tablet_h');
    if (x) tabletEl.style.left   = x;
    if (y) tabletEl.style.top    = y;
    if (w) tabletEl.style.width  = w;
    if (h) tabletEl.style.height = h;
  } catch (_) {}
}

function saveGeometry() {
  try {
    if (tabletEl.style.left)   localStorage.setItem('hobo_tablet_x', tabletEl.style.left);
    if (tabletEl.style.top)    localStorage.setItem('hobo_tablet_y', tabletEl.style.top);
    if (tabletEl.style.width)  localStorage.setItem('hobo_tablet_w', tabletEl.style.width);
    if (tabletEl.style.height) localStorage.setItem('hobo_tablet_h', tabletEl.style.height);
  } catch (_) {}
}

// NOTE: variable names below are deliberately prefixed `tab` to avoid colliding
// with `dragging` and `resizing` already declared as `var` in app.js (scanner).
// Both files share the same global scope; `let` against an existing `var` of the
// same name is a SyntaxError that kills the whole script.
const titlebar = document.querySelector('.tab-titlebar');
let tabDragging = false, tabDragSX = 0, tabDragSY = 0, tabPanSX = 0, tabPanSY = 0;

titlebar.addEventListener('mousedown', e => {
  // Don't trigger drag on the LEDs / buttons inside the titlebar
  if (e.target.closest('button, input, select')) return;
  tabDragging = true;
  tabDragSX   = e.clientX;
  tabDragSY   = e.clientY;
  const rect = tabletEl.getBoundingClientRect();
  tabPanSX = rect.left;
  tabPanSY = rect.top;
  e.preventDefault();
});

// Resize from corner handle
let tabResizing = false, tabResizeSX = 0, tabResizeSY = 0, tabStartW = 0, tabStartH = 0;

resizeHandle.addEventListener('mousedown', e => {
  tabResizing = true;
  tabResizeSX = e.clientX;
  tabResizeSY = e.clientY;
  tabStartW = tabletEl.offsetWidth;
  tabStartH = tabletEl.offsetHeight;
  e.preventDefault();
  e.stopPropagation();
});

document.addEventListener('mousemove', e => {
  if (tabDragging) {
    tabletEl.style.left = (tabPanSX + e.clientX - tabDragSX) + 'px';
    tabletEl.style.top  = (tabPanSY + e.clientY - tabDragSY) + 'px';
  }
  if (tabResizing) {
    const newW = Math.max(MIN_W, tabStartW + (e.clientX - tabResizeSX));
    const newH = Math.max(MIN_H, tabStartH + (e.clientY - tabResizeSY));
    tabletEl.style.width  = newW + 'px';
    tabletEl.style.height = newH + 'px';
  }
});

document.addEventListener('mouseup', () => {
  if (tabDragging || tabResizing) saveGeometry();
  tabDragging = false;
  tabResizing = false;
});

// ── Clock ────────────────────────────────────────────────────────────────────

let clockHandle = null;
function startClock() {
  stopClock();
  const tick = () => {
    const d = new Date();
    timeEl.textContent =
      String(d.getHours()).padStart(2, '0') + ':' +
      String(d.getMinutes()).padStart(2, '0') + ':' +
      String(d.getSeconds()).padStart(2, '0');
  };
  tick();
  clockHandle = setInterval(tick, 1000);
}
function stopClock() {
  if (clockHandle) clearInterval(clockHandle);
  clockHandle = null;
}

// ── Utils ────────────────────────────────────────────────────────────────────

function escapeHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
