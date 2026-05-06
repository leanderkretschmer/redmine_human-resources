(function () {
  'use strict';

  var snapshot = null;
  var fetchedAtClient = 0;
  var pollSeconds = 30;
  var statusUrl = null;
  var notifiedTarget = false;
  var notifiedBreak = false;
  var permissionAsked = false;
  var lastForcePollAt = 0;

  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function clampPos(n) { return n < 0 ? 0 : n; }

  function fmtHMS(seconds) {
    seconds = clampPos(Math.floor(seconds));
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    var s = seconds % 60;
    return pad(h) + ':' + pad(m) + ':' + pad(s);
  }
  function fmtHM(seconds) {
    seconds = clampPos(Math.floor(seconds));
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    return pad(h) + ':' + pad(m);
  }
  function fmtTimeOfDay(unix) {
    var d = new Date(unix * 1000);
    return pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function liveValues() {
    if (!snapshot) return null;
    var deltaSec = clampPos(Date.now() / 1000 - fetchedAtClient);
    var worked = snapshot.worked_seconds_today || 0;
    var currentBreak = snapshot.current_break_seconds || 0;
    var totalBreak = snapshot.total_break_seconds_today || 0;
    if (snapshot.state === 'working') {
      worked += deltaSec;
    } else if (snapshot.state === 'on_break') {
      currentBreak += deltaSec;
      totalBreak += deltaSec;
    }
    return { worked: worked, currentBreak: currentBreak, totalBreak: totalBreak };
  }

  function liveExpectedEnd() {
    if (!snapshot || !snapshot.expected_end_unix) return null;
    if (snapshot.state === 'on_break') {
      var deltaSec = clampPos(Date.now() / 1000 - fetchedAtClient);
      return snapshot.expected_end_unix + deltaSec;
    }
    return snapshot.expected_end_unix;
  }

  function getStateLabel(state) {
    if (snapshot && snapshot.labels && state === 'needs_correction' && snapshot.labels.needs_correction) {
      return snapshot.labels.needs_correction;
    }
    if (state === 'working') return 'Arbeitet';
    if (state === 'on_break') return 'Pause';
    if (state === 'needs_correction') return 'Korrektur erforderlich';
    return 'Ausgestempelt';
  }

  function findNavLink() {
    var el = document.getElementById('hm-timeclock-menu-link');
    if (el) return el;
    var candidates = document.querySelectorAll('#account a, #top-menu a, .account a');
    for (var i = 0; i < candidates.length; i++) {
      var href = candidates[i].getAttribute('href') || '';
      if (href.indexOf('/hm_timeclock') === 0) return candidates[i];
    }
    return null;
  }

  function updateNavbar() {
    var navLink = findNavLink();
    if (!navLink) return;

    var stamp = navLink.querySelector('.hm-tc-nav-time');
    if (!snapshot) {
      if (stamp) stamp.textContent = '';
      return;
    }

    if (!stamp) {
      stamp = document.createElement('span');
      stamp.className = 'hm-tc-nav-time';
      navLink.insertBefore(stamp, navLink.firstChild);
    }

    navLink.classList.remove('hm-tc-overtime', 'hm-tc-on-break', 'hm-tc-working', 'hm-tc-needs-correction');

    if (snapshot.state === 'idle') {
      stamp.textContent = '';
      stamp.style.display = 'none';
      return;
    }

    if (snapshot.state === 'needs_correction') {
      stamp.style.display = '';
      stamp.textContent = '⚠ ' + (snapshot.labels && snapshot.labels.needs_correction ? snapshot.labels.needs_correction : 'Korrektur') + ' ';
      navLink.classList.add('hm-tc-needs-correction');
      return;
    }

    var live = liveValues();
    stamp.style.display = '';
    var prefix = (snapshot.state === 'on_break') ? '⏸ ' : '▶ ';
    var ee = liveExpectedEnd();
    var endStr = '';
    if (ee && snapshot.daily_target_seconds > 0) {
      if (live.worked >= snapshot.daily_target_seconds) {
        endStr = ' ✓';
      } else {
        endStr = ' → ' + fmtTimeOfDay(ee);
      }
    }
    stamp.textContent = prefix + fmtHM(live.worked) + endStr + ' ';

    if (snapshot.state === 'on_break') {
      navLink.classList.add('hm-tc-on-break');
    } else {
      navLink.classList.add('hm-tc-working');
    }

    if (live.worked >= (snapshot.overtime_threshold_seconds || Infinity)) {
      navLink.classList.add('hm-tc-overtime');
    }
  }

  function updateCard() {
    var card = document.getElementById('hm-timeclock-card');
    if (!card || !snapshot) return;
    var live = liveValues();
    if (!live) return;

    var bound = card.querySelectorAll('[data-bind]');
    for (var i = 0; i < bound.length; i++) {
      var el = bound[i];
      var k = el.getAttribute('data-bind');
      if (k === 'worked') el.textContent = fmtHMS(live.worked);
      else if (k === 'break_total') el.textContent = fmtHM(live.totalBreak);
      else if (k === 'current_break') el.textContent = fmtHMS(live.currentBreak);
      else if (k === 'state-label') {
        el.textContent = getStateLabel(snapshot.state);
        el.className = 'hm-tc-status hm-tc-status-' + snapshot.state;
      } else if (k === 'expected_end') {
        var ee = liveExpectedEnd();
        if (!ee || !snapshot.daily_target_seconds) {
          el.textContent = '--:--';
        } else if (live.worked >= snapshot.daily_target_seconds) {
          el.textContent = (snapshot.labels && snapshot.labels.target_done) || '✓';
        } else {
          el.textContent = fmtTimeOfDay(ee);
        }
      }
    }

    var elements = card.querySelectorAll('[data-show-when]');
    for (var j = 0; j < elements.length; j++) {
      var sel = elements[j];
      var states = (sel.getAttribute('data-show-when') || '').split(',');
      sel.style.display = states.indexOf(snapshot.state) >= 0 ? '' : 'none';
    }

    var actions = card.querySelectorAll('[data-state-visible]');
    for (var k2 = 0; k2 < actions.length; k2++) {
      var btn = actions[k2];
      var states2 = (btn.getAttribute('data-state-visible') || '').split(',');
      var form = btn.closest('form');
      var target = form || btn;
      target.style.display = states2.indexOf(snapshot.state) >= 0 ? '' : 'none';
    }

    var overEl = card.querySelector('.hm-tc-clock-worked');
    if (overEl) {
      if (live.worked >= (snapshot.overtime_threshold_seconds || Infinity)) {
        overEl.classList.add('hm-tc-overtime');
      } else {
        overEl.classList.remove('hm-tc-overtime');
      }
    }
  }

  function showNotification(message) {
    if (!message) return;
    if (window.Notification && Notification.permission === 'granted') {
      try {
        var n = new Notification('Redmine HR', { body: message, tag: 'hm-tc-' + Date.now() });
        setTimeout(function () { try { n.close(); } catch (e) {} }, 12000);
      } catch (e) {
        showInPagePopup(message);
      }
    } else {
      showInPagePopup(message);
    }
  }

  function showInPagePopup(message) {
    var modal = document.getElementById('hm-tc-popup');
    if (!modal) {
      modal = document.createElement('div');
      modal.id = 'hm-tc-popup';
      modal.className = 'hm-tc-popup';
      modal.innerHTML =
        '<div class="hm-tc-popup-inner">' +
        '<div class="hm-tc-popup-msg"></div>' +
        '<button type="button" class="hm-tc-popup-close">OK</button>' +
        '</div>';
      document.body.appendChild(modal);
      modal.querySelector('.hm-tc-popup-close').addEventListener('click', function () {
        modal.classList.remove('open');
      });
      modal.addEventListener('click', function (e) {
        if (e.target === modal) modal.classList.remove('open');
      });
    }
    modal.querySelector('.hm-tc-popup-msg').textContent = message;
    modal.classList.add('open');
  }

  function maybeNotify() {
    if (!snapshot) return;
    var live = liveValues();
    if (!live) return;

    if (snapshot.state === 'idle' || snapshot.state === 'needs_correction') {
      notifiedTarget = false;
    }
    if (snapshot.state !== 'on_break') {
      notifiedBreak = false;
    }

    if (snapshot.notify_target_reached &&
        (snapshot.state === 'working' || snapshot.state === 'on_break') &&
        !notifiedTarget &&
        snapshot.daily_target_seconds > 0 &&
        live.worked >= snapshot.daily_target_seconds) {
      showNotification(snapshot.labels.target_reached);
      notifiedTarget = true;
    }

    if (snapshot.notify_break_over &&
        snapshot.state === 'on_break' &&
        !notifiedBreak &&
        snapshot.max_break_seconds > 0 &&
        live.currentBreak >= snapshot.max_break_seconds) {
      showNotification(snapshot.labels.break_over);
      notifiedBreak = true;
    }
  }

  function maybeForcePoll() {
    if (!snapshot) return;
    var nowSec = Date.now() / 1000;
    if (nowSec - lastForcePollAt < 5) return;
    var live = liveValues();
    if (!live) return;
    var trigger = false;
    if (snapshot.state === 'on_break' &&
        snapshot.max_break_seconds > 0 &&
        live.currentBreak >= snapshot.max_break_seconds) {
      trigger = true;
    }
    if (trigger) {
      lastForcePollAt = nowSec;
      fetchStatus().then(tick);
    }
  }

  function applySnapshot(data) {
    snapshot = data;
    fetchedAtClient = Date.now() / 1000;
    if (data && data.poll_interval_seconds) {
      pollSeconds = data.poll_interval_seconds;
    }
  }

  function fetchStatus() {
    if (!statusUrl) return Promise.resolve();
    return fetch(statusUrl, {
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json' },
      cache: 'no-store'
    })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) { if (data) applySnapshot(data); })
      .catch(function () {});
  }

  function tick() {
    updateCard();
    updateNavbar();
    maybeNotify();
    maybeForcePoll();
  }

  function schedulePoll() {
    setTimeout(function () {
      fetchStatus().then(function () {
        tick();
        schedulePoll();
      });
    }, Math.max(5, pollSeconds) * 1000);
  }

  function askPermissionOnce() {
    if (permissionAsked) return;
    permissionAsked = true;
    if (window.Notification && Notification.permission === 'default') {
      try { Notification.requestPermission(); } catch (e) {}
    }
    document.removeEventListener('click', askPermissionOnce);
    document.removeEventListener('keydown', askPermissionOnce);
  }

  function boot() {
    var card = document.getElementById('hm-timeclock-card');
    var bootCfg = (window.HmTimeclock && window.HmTimeclock.bootstrap) || {};

    if (card && card.dataset.statusUrl) {
      statusUrl = card.dataset.statusUrl;
    } else if (bootCfg.statusUrl) {
      statusUrl = bootCfg.statusUrl;
    }

    if (bootCfg.pollIntervalSeconds) {
      pollSeconds = bootCfg.pollIntervalSeconds;
    }

    if (card && card.dataset.snapshot) {
      try { applySnapshot(JSON.parse(card.dataset.snapshot)); } catch (e) {}
    } else if (bootCfg.snapshot) {
      applySnapshot(bootCfg.snapshot);
    }

    if (!snapshot) {
      fetchStatus().then(tick);
    } else {
      tick();
    }

    setInterval(tick, 1000);
    schedulePoll();

    document.addEventListener('click', askPermissionOnce);
    document.addEventListener('keydown', askPermissionOnce);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
