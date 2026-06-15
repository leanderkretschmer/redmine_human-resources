(function () {
  'use strict';

  var snapshot = null;
  var fetchedAtClient = 0;
  var pollSeconds = 30;
  var statusUrl = null;
  var notifiedTarget = false;
  var notifiedBreak = false;
  var notifiedBreakReminder = false;
  var permissionAsked = false;
  var lastForcePollAt = 0;
  // Set to true once the server has signalled this client is no longer
  // authenticated (401/403). Stops all subsequent polling so an idle tab
  // doesn't keep hammering /hr_timeclock/status.json with anonymous requests.
  var pollingStopped = false;
  var NAV_END_KEY = 'hr_show_navbar_end';

  function navEndEnabled() {
    try {
      var v = localStorage.getItem(NAV_END_KEY);
      return v === null || v === '1';
    } catch (e) { return true; }
  }
  function setNavEnd(enabled) {
    try { localStorage.setItem(NAV_END_KEY, enabled ? '1' : '0'); } catch (e) {}
  }

  function pad(n) { return n < 10 ? '0' + n : '' + n; }

  // Persist "already shown today" flags so popups fire once per day instead of
  // on every page navigation (each navigation reloads the in-memory state).
  function notifyDayKey() {
    var d = new Date();
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  }
  function notifyFlagStorageKey(kind) { return 'hr_tc_notified_' + kind + '_' + notifyDayKey(); }
  function loadNotifyFlag(kind) {
    try { return localStorage.getItem(notifyFlagStorageKey(kind)) === '1'; } catch (e) { return false; }
  }
  function persistNotifyFlag(kind, value) {
    try {
      if (value) localStorage.setItem(notifyFlagStorageKey(kind), '1');
      else localStorage.removeItem(notifyFlagStorageKey(kind));
    } catch (e) {}
  }
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
    var el = document.getElementById('hr-timeclock-menu-link') ||
             document.getElementById('hr-timeclock-menu-link');
    if (el) return el;
    var candidates = document.querySelectorAll('#account a, #top-menu a, .account a');
    for (var i = 0; i < candidates.length; i++) {
      var href = candidates[i].getAttribute('href') || '';
      if (href.indexOf('/hr_timeclock') === 0) return candidates[i];
    }
    return null;
  }

  function setupAbsenceModal() {
    var modal = document.getElementById('hr-absence-modal');
    if (!modal) return;
    if (modal.dataset.hrReady === '1') return;
    modal.dataset.hrReady = '1';

    function openModal(date, kindHint) {
      var startEl = modal.querySelector('#hr_absence_starts_on');
      var endEl   = modal.querySelector('#hr_absence_ends_on');
      var kindEl  = modal.querySelector('#hr_absence_kind');
      if (date && startEl) startEl.value = date;
      if (date && endEl)   endEl.value   = date;
      if (kindHint && kindEl) kindEl.value = kindHint;
      var rows = modal.querySelectorAll('.hr-tc-offsite-only');
      var showOffsite = kindEl && kindEl.value === 'offsite';
      rows.forEach(function (r) { r.hidden = !showOffsite; });
      modal.classList.add('open');
      modal.setAttribute('aria-hidden', 'false');
      var first = modal.querySelector('#hr_absence_kind, #hr_absence_starts_on');
      if (first) try { first.focus(); } catch (e) {}
    }
    function closeModal() {
      modal.classList.remove('open');
      modal.setAttribute('aria-hidden', 'true');
    }

    modal.addEventListener('click', function (e) {
      if (e.target === modal) closeModal();
    });
    var cancelBtn = modal.querySelector('.hr-tc-absence-modal-cancel');
    if (cancelBtn) cancelBtn.addEventListener('click', closeModal);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && modal.classList.contains('open')) closeModal();
    });

    var startEl = modal.querySelector('#hr_absence_starts_on');
    var endEl   = modal.querySelector('#hr_absence_ends_on');
    if (startEl && endEl) {
      startEl.addEventListener('change', function () {
        if (!endEl.value || endEl.value < startEl.value) endEl.value = startEl.value;
      });
    }

    var kindEl = modal.querySelector('#hr_absence_kind');
    var offsiteRows = modal.querySelectorAll('.hr-tc-offsite-only');
    function toggleOffsiteRows() {
      var show = kindEl && kindEl.value === 'offsite';
      offsiteRows.forEach(function (r) { r.hidden = !show; });
    }
    if (kindEl) {
      kindEl.addEventListener('change', toggleOffsiteRows);
      toggleOffsiteRows();
    }

    window.HrTimeclockOpenAbsenceModal = openModal;
  }

  function setupNavEndToggle() {
    var box = document.getElementById('hr-tc-toggle-nav-end');
    if (!box) return;
    box.checked = navEndEnabled();
    box.addEventListener('change', function () {
      setNavEnd(box.checked);
      updateNavbar();
    });
  }

  function setupAbsenceEditModal() {
    var modal = document.getElementById('hr-absence-edit-modal');
    if (!modal) return;

    function close() {
      modal.classList.remove('open');
      modal.setAttribute('aria-hidden', 'true');
    }

    function open(btn) {
      modal.dataset.updateUrl = btn.getAttribute('data-update-url') || '';
      var kindLabel = btn.getAttribute('data-kind-label') || '';
      var title = modal.querySelector('.hr-tc-absence-modal-title');
      if (title) title.textContent = (kindLabel ? kindLabel + ' — ' : '') + 'bearbeiten';
      modal.querySelector('#hr_absence_edit_starts_on').value = btn.getAttribute('data-starts-on') || '';
      modal.querySelector('#hr_absence_edit_ends_on').value   = btn.getAttribute('data-ends-on')   || '';
      modal.querySelector('#hr_absence_edit_reason').value    = btn.getAttribute('data-reason')    || '';
      var statusEl = modal.querySelector('#hr_absence_edit_status');
      if (statusEl) statusEl.value = btn.getAttribute('data-status') || 'requested';
      modal.classList.add('open');
      modal.setAttribute('aria-hidden', 'false');
    }

    function csrf() {
      var meta = document.querySelector('meta[name="csrf-token"]');
      return meta ? meta.getAttribute('content') : (modal.getAttribute('data-csrf') || '');
    }

    document.body.addEventListener('click', function (e) {
      var btn = e.target.closest('.hr-tc-edit-absence-btn');
      if (!btn) return;
      e.preventDefault();
      open(btn);
    });

    modal.addEventListener('click', function (e) {
      if (e.target === modal) close();
      if (e.target.classList.contains('hr-tc-absence-modal-cancel')) close();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && modal.classList.contains('open')) close();
    });

    var form = modal.querySelector('#hr-absence-edit-form');
    if (form) {
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        var url = modal.dataset.updateUrl;
        if (!url) return;
        var body = new URLSearchParams();
        body.append('hr_absence[starts_on]', modal.querySelector('#hr_absence_edit_starts_on').value);
        body.append('hr_absence[ends_on]',   modal.querySelector('#hr_absence_edit_ends_on').value);
        body.append('hr_absence[reason]',    modal.querySelector('#hr_absence_edit_reason').value);
        var statusEl = modal.querySelector('#hr_absence_edit_status');
        if (statusEl) body.append('hr_absence[status]', statusEl.value);
        body.append('_method', 'patch');

        var submitBtn = form.querySelector('button[type="submit"]');
        if (submitBtn) submitBtn.disabled = true;

        fetch(url, {
          method: 'POST',
          credentials: 'same-origin',
          headers: {
            'X-CSRF-Token': csrf(),
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded'
          },
          body: body.toString()
        }).then(function (r) {
          if (r.ok) {
            close();
            window.location.reload();
            return;
          }
          return r.json().then(function (data) {
            var msg = (data && (data.error || (data.errors && data.errors.join(', ')))) || ('HTTP ' + r.status);
            throw new Error(msg);
          }, function () { throw new Error('HTTP ' + r.status); });
        }).catch(function (err) {
          if (submitBtn) submitBtn.disabled = false;
          alert((err && err.message) || 'Speichern fehlgeschlagen');
        });
      });
    }
  }

  function setupCalendarInteractions() {
    var detailModal = document.getElementById('hr-day-detail-modal');
    var ctxMenu = document.getElementById('hr-tc-context-menu');
    var calendars = document.querySelectorAll('.hr-tc-calendar');
    if (!calendars.length) return;

    var dragState = null;
    var clickTimer = null;

    function cellDate(cell) { return cell && cell.getAttribute('data-date'); }
    function isInteractive(target) { return !!target.closest('a, button, .hr-tc-cal-day-link, .hr-tc-cal-user-pill'); }

    function highlightRange(fromDate, toDate) {
      if (!fromDate || !toDate) return;
      var lo = fromDate < toDate ? fromDate : toDate;
      var hi = fromDate > toDate ? fromDate : toDate;
      document.querySelectorAll('td.hr-tc-cal-clickable[data-date]').forEach(function (c) {
        var d = c.getAttribute('data-date');
        c.classList.toggle('hr-tc-cal-selected', d >= lo && d <= hi);
      });
    }

    function clearHighlight() {
      document.querySelectorAll('td.hr-tc-cal-selected').forEach(function (c) {
        c.classList.remove('hr-tc-cal-selected');
      });
    }

    function fetchDayDetail(date) {
      if (!detailModal) return;
      var urlBase = detailModal.getAttribute('data-url-base') || '';
      var placeholder = detailModal.getAttribute('data-url-placeholder') || '1970-01-01';
      var url = urlBase.replace(placeholder, date);
      detailModal.classList.add('open');
      detailModal.setAttribute('aria-hidden', 'false');
      var loading = detailModal.querySelector('.hr-tc-day-detail-loading');
      var events  = detailModal.querySelector('.hr-tc-day-detail-events');
      var title   = detailModal.querySelector('.hr-tc-day-detail-title');
      if (loading) { loading.hidden = false; loading.textContent = loading.dataset.defaultText || loading.textContent; }
      if (events)  events.hidden  = true;
      if (title)   title.textContent = date;
      detailModal.dataset.date = date;
      fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json' } })
        .then(function (r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.json();
        })
        .then(function (data) { renderDayDetail(data); })
        .catch(function (err) {
          if (loading) loading.textContent = '⚠ ' + (err && err.message ? err.message : 'Fehler beim Laden');
        });
    }

    function csrfToken() {
      var meta = document.querySelector('meta[name="csrf-token"]');
      return meta ? meta.getAttribute('content') : '';
    }

    function modalLabel(key, fallback) {
      if (!detailModal) return fallback;
      var v = detailModal.getAttribute('data-' + key);
      return v && v.length ? v : fallback;
    }

    function refreshActiveDay() {
      var date = detailModal && detailModal.dataset.date;
      if (date) fetchDayDetail(date);
    }

    function deleteAbsence(url, kindLabel) {
      if (!url) return;
      if (!confirm(modalLabel('confirm-delete', 'Wirklich löschen?'))) return;
      fetch(url, {
        method: 'DELETE',
        credentials: 'same-origin',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Accept': 'application/json'
        }
      }).then(function (r) {
        if (r.ok || r.status === 302) {
          refreshActiveDay();
        } else if (r.status === 404) {
          // bereits gelöscht — Modal frisch laden, dann ist es weg
          refreshActiveDay();
        } else {
          alert('Löschen fehlgeschlagen (' + r.status + ')');
        }
      }).catch(function () {
        alert('Löschen fehlgeschlagen');
      });
    }

    function renderInlineEdit(li, absence) {
      var fromLabel   = modalLabel('label-from',   'Von');
      var toLabel     = modalLabel('label-to',     'Bis');
      var reasonLabel = modalLabel('label-reason', 'Begründung');
      var saveLabel   = modalLabel('save-label',   'Speichern');
      var cancelLabel = modalLabel('cancel-label', 'Abbrechen');

      var formHtml =
        '<form class="hr-tc-day-event-form">' +
          '<div class="hr-tc-day-event-form-row">' +
            '<label>' + escapeHtml(fromLabel) + '</label>' +
            '<input type="date" name="starts_on" value="' + escapeHtml(absence.starts_on) + '" required>' +
          '</div>' +
          '<div class="hr-tc-day-event-form-row">' +
            '<label>' + escapeHtml(toLabel) + '</label>' +
            '<input type="date" name="ends_on" value="' + escapeHtml(absence.ends_on) + '" required>' +
          '</div>' +
          '<div class="hr-tc-day-event-form-row">' +
            '<label>' + escapeHtml(reasonLabel) + '</label>' +
            '<textarea name="reason" rows="2">' + escapeHtml(absence.reason || '') + '</textarea>' +
          '</div>' +
          '<div class="hr-tc-day-event-form-actions">' +
            '<button type="submit" class="button-positive hr-tc-day-event-form-save">' + escapeHtml(saveLabel) + '</button> ' +
            '<button type="button" class="hr-tc-day-event-form-cancel">' + escapeHtml(cancelLabel) + '</button>' +
          '</div>' +
        '</form>';

      var snapshot = li.innerHTML;
      li.innerHTML = formHtml;
      li.classList.add('hr-tc-day-event-editing');

      var form = li.querySelector('.hr-tc-day-event-form');
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        submitInlineEdit(absence, form, li, snapshot);
      });
      var cancelBtn = li.querySelector('.hr-tc-day-event-form-cancel');
      if (cancelBtn) cancelBtn.addEventListener('click', function () {
        li.innerHTML = snapshot;
        li.classList.remove('hr-tc-day-event-editing');
        rebindInlineHandlers(li, absence);
      });
    }

    function rebindInlineHandlers(li, absence) {
      var delBtn = li.querySelector('.hr-tc-day-event-delete');
      if (delBtn) {
        delBtn.addEventListener('click', function (e) {
          e.preventDefault();
          deleteAbsence(delBtn.getAttribute('data-url'), absence.kind_label);
        });
      }
      var editBtn = li.querySelector('.hr-tc-day-event-edit');
      if (editBtn) {
        editBtn.addEventListener('click', function (e) {
          e.preventDefault();
          renderInlineEdit(li, absence);
        });
      }
    }

    function submitInlineEdit(absence, form, li, snapshot) {
      var fd = new FormData(form);
      var body = new URLSearchParams();
      body.append('hr_absence[starts_on]', fd.get('starts_on'));
      body.append('hr_absence[ends_on]',   fd.get('ends_on'));
      body.append('hr_absence[reason]',    fd.get('reason'));
      body.append('_method', 'patch');

      var saveBtn = form.querySelector('.hr-tc-day-event-form-save');
      if (saveBtn) saveBtn.disabled = true;

      fetch(absence.edit_url.replace(/\/edit$/, ''), {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: body.toString()
      }).then(function (r) {
        if (r.ok) { refreshActiveDay(); return; }
        if (r.status === 404) {
          alert(modalLabel('label-not-found', 'Eintrag existiert nicht mehr.'));
          refreshActiveDay();
          return;
        }
        return r.json().then(function (data) {
          var msg = (data && (data.error || (data.errors && data.errors.join(', ')))) || ('HTTP ' + r.status);
          throw new Error(msg);
        }, function () { throw new Error('HTTP ' + r.status); });
      }).catch(function (err) {
        if (saveBtn) saveBtn.disabled = false;
        alert((err && err.message) || 'Speichern fehlgeschlagen');
      });
    }

    function renderDayDetail(data) {
      if (!data || !detailModal) return;
      var title   = detailModal.querySelector('.hr-tc-day-detail-title');
      var loading = detailModal.querySelector('.hr-tc-day-detail-loading');
      var events  = detailModal.querySelector('.hr-tc-day-detail-events');
      if (title)   title.textContent = data.date_label || data.date;
      if (loading) loading.hidden = true;
      if (events)  events.hidden  = false;

      var workUl = detailModal.querySelector('[data-bind="work"]');
      var workEmpty = detailModal.querySelector('[data-bind="work-empty"]');
      if (workUl) {
        workUl.innerHTML = '';
        var work = (data.events || []).filter(function (e) { return e.type === 'work'; });
        work.forEach(function (e) {
          var li = document.createElement('li');
          li.className = 'hr-tc-day-event hr-tc-day-event-work';
          var times = e.starts_label + ' – ' + e.ends_label;
          var net = ' (' + fmtHM(e.net_seconds) + ')';
          var html = '<strong>' + times + '</strong>' + net;
          if (e.breaks && e.breaks.length) {
            html += '<ul class="hr-tc-day-event-breaks">';
            e.breaks.forEach(function (b) {
              html += '<li>⏸ ' + b.starts_label + ' – ' + b.ends_label + ' (' + fmtHM(b.seconds) + ')</li>';
            });
            html += '</ul>';
          }
          li.innerHTML = html;
          workUl.appendChild(li);
        });
        if (workEmpty) workEmpty.hidden = work.length > 0;
      }

      var absUl = detailModal.querySelector('[data-bind="absences"]');
      var absEmpty = detailModal.querySelector('[data-bind="absences-empty"]');
      if (absUl) {
        absUl.innerHTML = '';
        var absences = data.absences || [];
        absences.forEach(function (a) {
          var li = document.createElement('li');
          li.className = 'hr-tc-day-event hr-tc-day-event-absence hr-tc-day-event-' + a.kind;
          li.dataset.absenceId = a.id;
          li.dataset.absenceKind = a.kind;
          var html = '<strong>' + escapeHtml(a.kind_label) + '</strong>';
          if (a.status && a.status !== 'approved') {
            html += ' · ' + escapeHtml(a.status_label);
          }
          if (a.starts_on !== a.ends_on) {
            html += ' · ' + a.starts_on + ' → ' + a.ends_on;
          }
          if (a.partial && a.start_time && a.end_time) {
            html += ' · ' + escapeHtml(a.start_time) + ' – ' + escapeHtml(a.end_time);
          }
          if (a.reason) html += '<div class="hr-tc-day-event-reason">' + escapeHtml(a.reason) + '</div>';
          html += '<div class="hr-tc-day-event-actions">';
          if (a.edit_url) {
            html += '<a href="#" class="icon icon-edit hr-tc-day-event-edit" title="' + escapeHtml(modalLabel('edit-label', 'Bearbeiten')) + '">' +
                    escapeHtml(modalLabel('edit-label', 'Bearbeiten')) + '</a>';
          }
          if (a.delete_url) {
            html += '<a href="#" class="icon icon-del hr-tc-day-event-delete" data-url="' + escapeHtml(a.delete_url) +
                    '" title="' + escapeHtml(modalLabel('delete-label', 'Löschen')) + '">' +
                    escapeHtml(modalLabel('delete-label', 'Löschen')) + '</a>';
          }
          html += '</div>';
          li.innerHTML = html;
          var delBtn = li.querySelector('.hr-tc-day-event-delete');
          if (delBtn) {
            delBtn.addEventListener('click', function (e) {
              e.preventDefault();
              deleteAbsence(delBtn.getAttribute('data-url'), a.kind_label);
            });
          }
          var editBtn = li.querySelector('.hr-tc-day-event-edit');
          if (editBtn) {
            editBtn.addEventListener('click', function (e) {
              e.preventDefault();
              renderInlineEdit(li, a);
            });
          }
          absUl.appendChild(li);
        });
        if (absEmpty) absEmpty.hidden = absences.length > 0;
      }

      renderTimeline(data);
    }

    function minutesFromTimeStr(s) {
      if (!s) return null;
      var m = String(s).match(/^(\d{1,2}):(\d{2})/);
      if (!m) return null;
      return parseInt(m[1], 10) * 60 + parseInt(m[2], 10);
    }
    function minutesFromUnix(unix, dateIso) {
      if (!unix) return null;
      var d = new Date(unix * 1000);
      var dayStart = new Date(dateIso + 'T00:00:00');
      var diff = (d.getTime() - dayStart.getTime()) / 60000;
      if (diff < 0) return 0;
      if (diff > 24 * 60) return 24 * 60;
      return diff;
    }
    function fmtMinutes(m) {
      m = Math.max(0, Math.min(24 * 60, Math.round(m)));
      var h = Math.floor(m / 60);
      var mm = m % 60;
      return (h < 10 ? '0' : '') + h + ':' + (mm < 10 ? '0' : '') + mm;
    }
    function snap15(m) { return Math.round(m / 15) * 15; }

    function renderTimeline(data) {
      var tl = detailModal.querySelector('[data-bind="timeline"]');
      if (!tl) return;
      var axis  = tl.querySelector('[data-bind="timeline-axis"]');
      var bands = tl.querySelector('[data-bind="timeline-bands"]');
      if (!axis || !bands) return;
      var startH = parseInt(tl.getAttribute('data-start-hour') || '0', 10);
      var endH   = parseInt(tl.getAttribute('data-end-hour')   || '24', 10);
      var totalMin = (endH - startH) * 60;
      tl.dataset.date = data.date;

      axis.innerHTML = '';
      for (var h = startH; h <= endH; h += 4) {
        var t = document.createElement('span');
        t.className = 'hr-tc-day-timeline-tick';
        t.style.left = ((h - startH) / (endH - startH) * 100).toFixed(2) + '%';
        t.textContent = (h < 10 ? '0' : '') + h + ':00';
        axis.appendChild(t);
      }

      bands.innerHTML = '';
      function placeBand(fromMin, toMin, cls, label) {
        if (toMin <= fromMin) return;
        var left  = Math.max(0, (fromMin - startH * 60) / totalMin * 100);
        var width = Math.min(100 - left, (toMin - fromMin) / totalMin * 100);
        if (width <= 0) return;
        var el = document.createElement('div');
        el.className = 'hr-tc-day-band ' + cls;
        el.style.left  = left.toFixed(2) + '%';
        el.style.width = width.toFixed(2) + '%';
        el.title = label || '';
        bands.appendChild(el);
      }

      (data.events || []).filter(function (e) { return e.type === 'work'; }).forEach(function (e) {
        var s = minutesFromUnix(e.starts_at_unix, data.date);
        var t = minutesFromUnix(e.ends_at_unix,   data.date);
        if (s === null || t === null) return;
        placeBand(s, t, 'hr-tc-day-band-work', e.starts_label + ' – ' + e.ends_label);
      });
      (data.absences || []).forEach(function (a) {
        var cls = 'hr-tc-day-band-absence hr-tc-day-band-' + a.kind;
        if (a.partial && a.start_time && a.end_time) {
          var s = minutesFromTimeStr(a.start_time);
          var t = minutesFromTimeStr(a.end_time);
          if (s !== null && t !== null) {
            placeBand(s, t, cls + ' hr-tc-day-band-partial', (a.kind_label || '') + ' ' + a.start_time + '–' + a.end_time);
          }
        } else {
          placeBand(startH * 60, endH * 60, cls + ' hr-tc-day-band-full', a.kind_label || '');
        }
      });
    }

    function setupTimelineInteractions() {
      var tl = detailModal && detailModal.querySelector('[data-bind="timeline"]');
      if (!tl) return;
      var track = tl.querySelector('.hr-tc-day-timeline-track');
      var sel   = tl.querySelector('[data-bind="timeline-selection"]');
      var pop   = detailModal.querySelector('[data-bind="timeline-popover"]');
      if (!track || !sel || !pop) return;

      var dragging = false;
      var dragStart = 0;
      var dragEnd = 0;

      function rectMin(e) {
        var r = track.getBoundingClientRect();
        var x = e.clientX - r.left;
        var startH = parseInt(tl.getAttribute('data-start-hour') || '0', 10);
        var endH   = parseInt(tl.getAttribute('data-end-hour')   || '24', 10);
        var totalMin = (endH - startH) * 60;
        var m = startH * 60 + (x / r.width) * totalMin;
        return Math.max(startH * 60, Math.min(endH * 60, m));
      }
      function updateSel() {
        var lo = Math.min(dragStart, dragEnd);
        var hi = Math.max(dragStart, dragEnd);
        var startH = parseInt(tl.getAttribute('data-start-hour') || '0', 10);
        var endH   = parseInt(tl.getAttribute('data-end-hour')   || '24', 10);
        var totalMin = (endH - startH) * 60;
        sel.hidden = false;
        sel.style.left  = ((lo - startH * 60) / totalMin * 100).toFixed(2) + '%';
        sel.style.width = ((hi - lo) / totalMin * 100).toFixed(2) + '%';
      }

      track.addEventListener('mousedown', function (e) {
        if (e.target.classList.contains('hr-tc-day-band')) return;
        dragging = true;
        dragStart = dragEnd = rectMin(e);
        updateSel();
        e.preventDefault();
      });
      document.addEventListener('mousemove', function (e) {
        if (!dragging) return;
        dragEnd = rectMin(e);
        updateSel();
      });
      document.addEventListener('mouseup', function (e) {
        if (!dragging) return;
        dragging = false;
        var lo = snap15(Math.min(dragStart, dragEnd));
        var hi = snap15(Math.max(dragStart, dragEnd));
        if (hi - lo < 15) { sel.hidden = true; return; }
        showTimelinePopover(lo, hi, e);
      });

      pop.querySelector('[data-bind="popover-cancel"]').addEventListener('click', function () {
        pop.hidden = true;
        sel.hidden = true;
      });
      pop.querySelector('[data-bind="popover-save"]').addEventListener('click', function () {
        submitTimelineCreate();
      });
      var kindSel = pop.querySelector('[data-bind="popover-kind"]');
      if (kindSel) kindSel.addEventListener('change', updateTimelineRecurrenceVisibility);
      var recSel = pop.querySelector('[data-bind="popover-recurrence"]');
      if (recSel) recSel.addEventListener('change', updateTimelineRecurrenceVisibility);
    }

    // Sickness on the timeline is a one-off event; only "still working but
    // off-site / school / planned block" kinds may repeat. Values must match
    // the HrAbsence::KIND_* constants exactly (note: KIND_BLOCK = 'blocked').
    var TIMELINE_RECURRENCE_KINDS = ['offsite', 'school', 'blocked', 'homeoffice', 'workday'];

    function updateTimelineRecurrenceVisibility() {
      var pop = detailModal && detailModal.querySelector('[data-bind="timeline-popover"]');
      if (!pop) return;
      var kindSel = pop.querySelector('[data-bind="popover-kind"]');
      var recRow  = pop.querySelector('[data-bind="popover-recurrence-row"]');
      var recSel  = pop.querySelector('[data-bind="popover-recurrence"]');
      var untilRow = pop.querySelector('[data-bind="popover-recurrence-until-row"]');
      if (!kindSel || !recRow || !recSel || !untilRow) return;
      var capable = TIMELINE_RECURRENCE_KINDS.indexOf(kindSel.value) !== -1;
      recRow.hidden = !capable;
      if (!capable) {
        recSel.value = 'none';
        untilRow.hidden = true;
        return;
      }
      untilRow.hidden = recSel.value === 'none' || !recSel.value;
    }

    function showTimelinePopover(loMin, hiMin, evt) {
      var tl  = detailModal.querySelector('[data-bind="timeline"]');
      var pop = detailModal.querySelector('[data-bind="timeline-popover"]');
      if (!pop || !tl) return;
      pop.hidden = false;
      pop.querySelector('[data-bind="popover-from"]').value = fmtMinutes(loMin);
      pop.querySelector('[data-bind="popover-to"]').value   = fmtMinutes(hiMin);
      pop.querySelector('[data-bind="popover-reason"]').value = '';
      var recSel = pop.querySelector('[data-bind="popover-recurrence"]');
      if (recSel) recSel.value = 'none';
      var untilInput = pop.querySelector('[data-bind="popover-recurrence-until"]');
      if (untilInput) untilInput.value = '';
      updateTimelineRecurrenceVisibility();
      // Reason input gets focus to let the user type the reason directly.
      setTimeout(function () { pop.querySelector('[data-bind="popover-reason"]').focus(); }, 0);
    }

    function submitTimelineCreate() {
      var pop = detailModal.querySelector('[data-bind="timeline-popover"]');
      var sel = detailModal.querySelector('[data-bind="timeline-selection"]');
      var date = detailModal.dataset.date;
      var newUrl = detailModal.getAttribute('data-new-url');
      if (!pop || !date || !newUrl) return;

      var kind = pop.querySelector('[data-bind="popover-kind"]').value;
      var from = pop.querySelector('[data-bind="popover-from"]').value;
      var to   = pop.querySelector('[data-bind="popover-to"]').value;
      var reason = pop.querySelector('[data-bind="popover-reason"]').value;
      if (!from || !to || from >= to) { return; }

      var recSel   = pop.querySelector('[data-bind="popover-recurrence"]');
      var untilInp = pop.querySelector('[data-bind="popover-recurrence-until"]');
      var recurrence      = recSel ? recSel.value : '';
      var recurrenceUntil = untilInp ? untilInp.value : '';
      var recurring = TIMELINE_RECURRENCE_KINDS.indexOf(kind) !== -1 &&
                      recurrence && recurrence !== 'none';

      var token = (document.querySelector('meta[name="csrf-token"]') || {}).content || '';
      var fd = new FormData();
      fd.append('hr_absence[kind]', kind);
      fd.append('hr_absence[starts_on]', date);
      fd.append('hr_absence[ends_on]',   date);
      fd.append('hr_absence[start_time]', from);
      fd.append('hr_absence[end_time]',   to);
      fd.append('hr_absence[reason]', reason);
      if (recurring) {
        fd.append('hr_absence[recurrence]', recurrence);
        fd.append('hr_absence[recurrence_until]', recurrenceUntil);
      }
      fd.append('authenticity_token', token);

      var saveBtn = pop.querySelector('[data-bind="popover-save"]');
      if (saveBtn) saveBtn.disabled = true;
      fetch(newUrl, {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Accept': 'application/json', 'X-CSRF-Token': token },
        body: fd
      }).then(function (r) {
        if (saveBtn) saveBtn.disabled = false;
        if (!r.ok) return r.text().then(function (t) {
          var msg = t;
          try { var j = JSON.parse(t); msg = j.error || j.message || t; } catch (e) {}
          alert(msg || ('HTTP ' + r.status));
        });
        pop.hidden = true;
        if (sel) sel.hidden = true;
        fetchDayDetail(date);
      }).catch(function (err) {
        if (saveBtn) saveBtn.disabled = false;
        alert((err && err.message) || 'Speichern fehlgeschlagen');
      });
    }

    setupTimelineInteractions();

    function escapeHtml(s) {
      return String(s).replace(/[&<>"']/g, function (c) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
      });
    }

    function closeDetail() {
      if (!detailModal) return;
      detailModal.classList.remove('open');
      detailModal.setAttribute('aria-hidden', 'true');
    }

    function openAbsenceModalFor(starts, ends, kindHint) {
      if (!window.HrTimeclockOpenAbsenceModal) return;
      window.HrTimeclockOpenAbsenceModal(starts, kindHint);
      var endEl = document.querySelector('#hr_absence_ends_on');
      if (endEl && ends) endEl.value = ends;
    }

    function closeContextMenu() {
      if (!ctxMenu) return;
      ctxMenu.hidden = true;
      ctxMenu.removeAttribute('data-date');
    }

    function openContextMenu(x, y, date) {
      if (!ctxMenu) return;
      ctxMenu.hidden = false;
      ctxMenu.style.left = x + 'px';
      ctxMenu.style.top  = y + 'px';
      ctxMenu.dataset.date = date;
    }

    if (detailModal) {
      detailModal.addEventListener('click', function (e) {
        if (e.target === detailModal) closeDetail();
        var newBtn = e.target.closest('.hr-tc-day-detail-new');
        if (newBtn) {
          var date = detailModal.dataset.date;
          closeDetail();
          openAbsenceModalFor(date, date, newBtn.getAttribute('data-default-kind'));
        }
        if (e.target.classList.contains('hr-tc-day-detail-close') ||
            e.target.classList.contains('hr-tc-popup-close')) {
          closeDetail();
        }
      });
    }

    if (ctxMenu) {
      ctxMenu.addEventListener('click', function (e) {
        var li = e.target.closest('li[data-action]');
        if (!li) return;
        var date = ctxMenu.dataset.date;
        closeContextMenu();
        var action = li.getAttribute('data-action');
        if (action === 'new-vacation') openAbsenceModalFor(date, date, 'vacation');
        else if (action === 'new-sickness') openAbsenceModalFor(date, date, 'sickness');
        else if (action === 'new-offsite')  openAbsenceModalFor(date, date, 'offsite');
        else if (action === 'detail') fetchDayDetail(date);
      });
      document.addEventListener('click', function (e) {
        if (!ctxMenu.hidden && !ctxMenu.contains(e.target)) closeContextMenu();
      });
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') {
          closeContextMenu();
          closeDetail();
        }
      });
    }

    calendars.forEach(function (cal) {
      var defaultKind = cal.getAttribute('data-default-absence-kind') || 'vacation';
      var adminCreate = cal.getAttribute('data-admin-create') === '1';

      cal.addEventListener('mousedown', function (e) {
        if (e.button !== 0) return;
        var cell = e.target.closest('td.hr-tc-cal-clickable[data-date]');
        if (!cell || isInteractive(e.target)) return;
        dragState = {
          startDate: cellDate(cell),
          endDate: cellDate(cell),
          moved: false,
          defaultKind: defaultKind
        };
        highlightRange(dragState.startDate, dragState.endDate);
      });

      cal.addEventListener('mouseover', function (e) {
        if (!dragState) return;
        var cell = e.target.closest('td.hr-tc-cal-clickable[data-date]');
        if (!cell) return;
        var d = cellDate(cell);
        if (d !== dragState.endDate) {
          dragState.endDate = d;
          dragState.moved = true;
          highlightRange(dragState.startDate, dragState.endDate);
        }
      });

      cal.addEventListener('contextmenu', function (e) {
        var cell = e.target.closest('td.hr-tc-cal-clickable[data-date]');
        if (!cell) return;
        e.preventDefault();
        openContextMenu(e.pageX, e.pageY, cellDate(cell));
      });

      cal.addEventListener('dblclick', function (e) {
        var cell = e.target.closest('td.hr-tc-cal-clickable[data-date]');
        if (!cell) return;
        if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
        var ids = cell.getAttribute('data-absence-ids');
        if (ids && !adminCreate) {
          var firstId = ids.split(',')[0];
          if (firstId) window.location.href = '/hr_absences/' + firstId + '/edit';
        } else {
          openAbsenceModalFor(cellDate(cell), cellDate(cell), defaultKind);
        }
      });

      cal.addEventListener('click', function (e) {
        if (isInteractive(e.target)) return;
        var cell = e.target.closest('td.hr-tc-cal-clickable[data-date]');
        if (!cell) return;
        if (clickTimer) clearTimeout(clickTimer);
        // In admin mode (global calendar), single-click on cell body opens the
        // absence modal for that day. The day-link itself is wrapped in an <a>
        // (covered by isInteractive above) so navigation to /admin/.../day/X
        // still works when clicking the date number specifically.
        if (adminCreate) {
          clickTimer = setTimeout(function () {
            openAbsenceModalFor(cellDate(cell), cellDate(cell), defaultKind);
            clickTimer = null;
          }, 220);
        } else {
          clickTimer = setTimeout(function () {
            fetchDayDetail(cellDate(cell));
            clickTimer = null;
          }, 220);
        }
      });
    });

    document.addEventListener('mouseup', function () {
      if (!dragState) return;
      var lo = dragState.startDate < dragState.endDate ? dragState.startDate : dragState.endDate;
      var hi = dragState.startDate > dragState.endDate ? dragState.startDate : dragState.endDate;
      var moved = dragState.moved;
      var kind = dragState.defaultKind;
      dragState = null;
      if (moved && lo && hi) {
        if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
        clearHighlight();
        openAbsenceModalFor(lo, hi, kind);
      } else {
        clearHighlight();
      }
    });
  }

  function setupHrDropdown() {
    var navLink = findNavLink();
    if (!navLink) return;
    if (navLink.dataset.hrDropdownReady === '1') return;
    var bootCfg = (window.HrTimeclock && window.HrTimeclock.bootstrap) || {};
    var items = bootCfg.menuItems || [];
    if (!items.length) return;

    navLink.dataset.hrDropdownReady = '1';
    var host = navLink.closest('li') || navLink.parentNode;
    if (!host) return;
    host.classList.add('hr-hr-dropdown');

    var menu = document.createElement('ul');
    menu.className = 'hr-hr-dropdown-menu';
    items.forEach(function (item) {
      var li = document.createElement('li');
      var a  = document.createElement('a');
      a.href = item.url;
      a.textContent = item.label;
      li.appendChild(a);
      menu.appendChild(li);
    });
    host.appendChild(menu);

    navLink.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') {
        host.classList.toggle('open');
      }
    });
    document.addEventListener('click', function (e) {
      if (!host.contains(e.target)) host.classList.remove('open');
    });
  }

  function updateNavbar() {
    var navLink = findNavLink();
    if (!navLink) return;

    var stamp = navLink.querySelector('.hr-tc-nav-time');
    if (!snapshot) {
      if (stamp) stamp.textContent = '';
      return;
    }

    if (!stamp) {
      stamp = document.createElement('span');
      stamp.className = 'hr-tc-nav-time';
      navLink.insertBefore(stamp, navLink.firstChild);
    }

    navLink.classList.remove('hr-tc-overtime', 'hr-tc-on-break', 'hr-tc-working', 'hr-tc-needs-correction');

    if (snapshot.state === 'idle') {
      stamp.textContent = '';
      stamp.style.display = 'none';
      return;
    }

    if (snapshot.state === 'needs_correction') {
      stamp.style.display = '';
      stamp.textContent = '⚠ ' + (snapshot.labels && snapshot.labels.needs_correction ? snapshot.labels.needs_correction : 'Korrektur') + ' ';
      navLink.classList.add('hr-tc-needs-correction');
      return;
    }

    var live = liveValues();
    stamp.style.display = '';
    var prefix = (snapshot.state === 'on_break') ? '⏸ ' : '▶ ';
    var overtimePrefix = (snapshot.labels && snapshot.labels.overtime_prefix) || '+';
    var endStr = '';
    if (navEndEnabled()) {
      if (snapshot.daily_target_seconds > 0 && live.worked >= snapshot.daily_target_seconds) {
        var over = live.worked - snapshot.daily_target_seconds;
        endStr = ' ' + overtimePrefix + fmtHM(over);
      } else {
        var ee = liveExpectedEnd();
        if (ee && snapshot.daily_target_seconds > 0) {
          endStr = ' → ' + fmtTimeOfDay(ee);
        }
      }
    }
    stamp.textContent = prefix + fmtHM(live.worked) + endStr + ' ';

    if (snapshot.state === 'on_break') {
      navLink.classList.add('hr-tc-on-break');
    } else {
      navLink.classList.add('hr-tc-working');
    }

    if (live.worked >= (snapshot.overtime_threshold_seconds || Infinity)) {
      navLink.classList.add('hr-tc-overtime');
    }
  }

  function updateCard() {
    var card = document.getElementById('hr-timeclock-card');
    if (!card || !snapshot) return;
    var live = liveValues();
    if (!live) return;

    var inOvertime = snapshot.daily_target_seconds > 0 &&
                     live.worked >= snapshot.daily_target_seconds;
    var overtimePrefix = (snapshot.labels && snapshot.labels.overtime_prefix) || '+';

    var bound = card.querySelectorAll('[data-bind]');
    for (var i = 0; i < bound.length; i++) {
      var el = bound[i];
      var k = el.getAttribute('data-bind');
      if (k === 'worked') el.textContent = fmtHMS(live.worked);
      else if (k === 'break_total') el.textContent = fmtHM(live.totalBreak);
      else if (k === 'current_break') el.textContent = fmtHMS(live.currentBreak);
      else if (k === 'state-label') {
        el.textContent = getStateLabel(snapshot.state);
        el.className = 'hr-tc-status hr-tc-status-' + snapshot.state;
      } else if (k === 'expected_end') {
        var ee = liveExpectedEnd();
        if (!ee || !snapshot.daily_target_seconds) {
          el.textContent = '--:--';
        } else {
          el.textContent = fmtTimeOfDay(ee);
        }
      } else if (k === 'overtime') {
        var over = inOvertime ? (live.worked - snapshot.daily_target_seconds) : 0;
        el.textContent = overtimePrefix + fmtHM(over);
      }
    }

    var elements = card.querySelectorAll('[data-show-when]');
    for (var j = 0; j < elements.length; j++) {
      var sel = elements[j];
      var states = (sel.getAttribute('data-show-when') || '').split(',');
      var stateVisible = states.indexOf(snapshot.state) >= 0;
      var hideWhenOvertime = sel.getAttribute('data-hide-when-overtime') === '1';
      var showWhenOvertime = sel.getAttribute('data-show-when-overtime') === '1';
      var visible = stateVisible;
      if (hideWhenOvertime && inOvertime) visible = false;
      if (showWhenOvertime && !inOvertime) visible = false;
      sel.style.display = visible ? '' : 'none';
    }

    var actions = card.querySelectorAll('[data-state-visible]');
    for (var k2 = 0; k2 < actions.length; k2++) {
      var btn = actions[k2];
      var states2 = (btn.getAttribute('data-state-visible') || '').split(',');
      var form = btn.closest('form');
      var target = form || btn;
      target.style.display = states2.indexOf(snapshot.state) >= 0 ? '' : 'none';
    }

    var overEl = card.querySelector('.hr-tc-clock-worked');
    if (overEl) {
      if (live.worked >= (snapshot.overtime_threshold_seconds || Infinity)) {
        overEl.classList.add('hr-tc-overtime');
      } else {
        overEl.classList.remove('hr-tc-overtime');
      }
    }
  }

  function showNotification(message) {
    if (!message) return;
    if (window.Notification && Notification.permission === 'granted') {
      try {
        var n = new Notification('Redmine HR', { body: message, tag: 'hr-tc-' + Date.now() });
        setTimeout(function () { try { n.close(); } catch (e) {} }, 12000);
      } catch (e) {
        showInPagePopup(message);
      }
    } else {
      showInPagePopup(message);
    }
  }

  function showInPagePopup(message) {
    var modal = document.getElementById('hr-tc-popup');
    if (!modal) {
      modal = document.createElement('div');
      modal.id = 'hr-tc-popup';
      modal.className = 'hr-tc-popup';
      modal.innerHTML =
        '<div class="hr-tc-popup-inner">' +
        '<div class="hr-tc-popup-msg"></div>' +
        '<button type="button" class="hr-tc-popup-close">OK</button>' +
        '</div>';
      document.body.appendChild(modal);
      modal.querySelector('.hr-tc-popup-close').addEventListener('click', function () {
        modal.classList.remove('open');
      });
      modal.addEventListener('click', function (e) {
        if (e.target === modal) modal.classList.remove('open');
      });
    }
    modal.querySelector('.hr-tc-popup-msg').textContent = message;
    modal.classList.add('open');
  }

  function maybeNotify() {
    if (!snapshot) return;
    var live = liveValues();
    if (!live) return;

    if (snapshot.state === 'idle' || snapshot.state === 'needs_correction') {
      if (notifiedTarget) { notifiedTarget = false; persistNotifyFlag('target', false); }
      if (notifiedBreakReminder) { notifiedBreakReminder = false; persistNotifyFlag('break_reminder', false); }
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
      persistNotifyFlag('target', true);
    }

    if (snapshot.break_reminder_enabled &&
        snapshot.state === 'working' &&
        !notifiedBreakReminder &&
        snapshot.break_reminder_seconds > 0 &&
        live.worked >= snapshot.break_reminder_seconds) {
      showNotification(snapshot.labels.break_reminder);
      notifiedBreakReminder = true;
      persistNotifyFlag('break_reminder', true);
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
    if (!snapshot || pollingStopped) return;
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
    if (!statusUrl || pollingStopped) return Promise.resolve();
    return fetch(statusUrl, {
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json' },
      cache: 'no-store'
    })
      .then(function (r) {
        if (r.status === 401 || r.status === 403) {
          pollingStopped = true;
          return null;
        }
        return r.ok ? r.json() : null;
      })
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
    if (pollingStopped) return;
    setTimeout(function () {
      if (pollingStopped) return;
      fetchStatus().then(function () {
        tick();
        schedulePoll();
      });
    }, Math.max(5, pollSeconds) * 1000);
  }

  // Admin global calendar: clicking a holiday-flagged day opens a popover that
  // lists the affected vs. unaffected users for that day's regional holiday(s).
  function setupHolidayPopover() {
    var pop = document.getElementById('hr-tc-holiday-popover');
    if (!pop) return;
    var affectedLabel = pop.dataset.affectedLabel || 'Affected';
    var unaffectedLabel = pop.dataset.unaffectedLabel || 'Not affected';
    function close() { pop.hidden = true; pop.innerHTML = ''; }
    document.addEventListener('click', function (e) {
      var cell = e.target.closest && e.target.closest('td.hr-tc-cal-holiday');
      if (!cell || !cell.dataset.holidayDetail) {
        if (!e.target.closest || !e.target.closest('#hr-tc-holiday-popover')) close();
        return;
      }
      // Don't fight other handlers when the click is on a link inside the cell.
      if (e.target.closest('a')) return;
      e.preventDefault();
      var data;
      try { data = JSON.parse(cell.dataset.holidayDetail); } catch (err) { return; }
      var parts = data.map(function (h) {
        var aff = (h.affected || []).map(function (n) { return '<li>' + escapeHtml(n) + '</li>'; }).join('') || '<li class="hr-tc-holiday-empty">—</li>';
        var unaff = (h.unaffected || []).map(function (n) { return '<li>' + escapeHtml(n) + '</li>'; }).join('') || '<li class="hr-tc-holiday-empty">—</li>';
        return '<div class="hr-tc-holiday-block">' +
                 '<div class="hr-tc-holiday-name">' + escapeHtml(h.name) + ' <span class="hr-tc-holiday-regions">(' + escapeHtml((h.regions || []).join(', ')) + ')</span></div>' +
                 '<div class="hr-tc-holiday-cols">' +
                   '<div><strong>' + escapeHtml(affectedLabel) + '</strong><ul>' + aff + '</ul></div>' +
                   '<div><strong>' + escapeHtml(unaffectedLabel) + '</strong><ul>' + unaff + '</ul></div>' +
                 '</div>' +
               '</div>';
      }).join('');
      pop.innerHTML = parts + '<button type="button" class="hr-tc-holiday-close">×</button>';
      pop.hidden = false;
      var r = cell.getBoundingClientRect();
      pop.style.position = 'absolute';
      pop.style.top  = (window.scrollY + r.bottom + 6) + 'px';
      pop.style.left = (window.scrollX + r.left) + 'px';
      pop.querySelector('.hr-tc-holiday-close').addEventListener('click', close);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') close();
    });
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
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
    var card = document.getElementById('hr-timeclock-card');
    var bootCfg = (window.HrTimeclock && window.HrTimeclock.bootstrap) || {};

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

    setupHrDropdown();
    setupAbsenceModal();
    setupCalendarInteractions();
    setupAbsenceEditModal();
    setupNavEndToggle();
    setupHolidayPopover();

    notifiedTarget = loadNotifyFlag('target');
    notifiedBreakReminder = loadNotifyFlag('break_reminder');

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
