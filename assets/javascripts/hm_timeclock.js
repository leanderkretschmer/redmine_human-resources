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

  function setupAbsenceModal() {
    var modal = document.getElementById('hm-absence-modal');
    if (!modal) return;
    if (modal.dataset.hmReady === '1') return;
    modal.dataset.hmReady = '1';

    function openModal(date, kindHint) {
      var startEl = modal.querySelector('#hm_absence_starts_on');
      var endEl   = modal.querySelector('#hm_absence_ends_on');
      var kindEl  = modal.querySelector('#hm_absence_kind');
      if (date && startEl) startEl.value = date;
      if (date && endEl)   endEl.value   = date;
      if (kindHint && kindEl) kindEl.value = kindHint;
      modal.classList.add('open');
      modal.setAttribute('aria-hidden', 'false');
      var first = modal.querySelector('#hm_absence_kind, #hm_absence_starts_on');
      if (first) try { first.focus(); } catch (e) {}
    }
    function closeModal() {
      modal.classList.remove('open');
      modal.setAttribute('aria-hidden', 'true');
    }

    modal.addEventListener('click', function (e) {
      if (e.target === modal) closeModal();
    });
    var cancelBtn = modal.querySelector('.hm-tc-absence-modal-cancel');
    if (cancelBtn) cancelBtn.addEventListener('click', closeModal);
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && modal.classList.contains('open')) closeModal();
    });

    var startEl = modal.querySelector('#hm_absence_starts_on');
    var endEl   = modal.querySelector('#hm_absence_ends_on');
    if (startEl && endEl) {
      startEl.addEventListener('change', function () {
        if (!endEl.value || endEl.value < startEl.value) endEl.value = startEl.value;
      });
    }

    window.HmTimeclockOpenAbsenceModal = openModal;
  }

  function setupCalendarInteractions() {
    var detailModal = document.getElementById('hm-day-detail-modal');
    var ctxMenu = document.getElementById('hm-tc-context-menu');
    var calendars = document.querySelectorAll('.hm-tc-calendar');
    if (!calendars.length) return;

    var dragState = null;
    var clickTimer = null;

    function cellDate(cell) { return cell && cell.getAttribute('data-date'); }
    function isInteractive(target) { return !!target.closest('a, button, .hm-tc-cal-day-link, .hm-tc-cal-user-pill'); }

    function highlightRange(fromDate, toDate) {
      if (!fromDate || !toDate) return;
      var lo = fromDate < toDate ? fromDate : toDate;
      var hi = fromDate > toDate ? fromDate : toDate;
      document.querySelectorAll('td.hm-tc-cal-clickable[data-date]').forEach(function (c) {
        var d = c.getAttribute('data-date');
        c.classList.toggle('hm-tc-cal-selected', d >= lo && d <= hi);
      });
    }

    function clearHighlight() {
      document.querySelectorAll('td.hm-tc-cal-selected').forEach(function (c) {
        c.classList.remove('hm-tc-cal-selected');
      });
    }

    function fetchDayDetail(date) {
      if (!detailModal) return;
      var urlBase = detailModal.getAttribute('data-url-base') || '';
      var placeholder = detailModal.getAttribute('data-url-placeholder') || '1970-01-01';
      var url = urlBase.replace(placeholder, date);
      detailModal.classList.add('open');
      detailModal.setAttribute('aria-hidden', 'false');
      var loading = detailModal.querySelector('.hm-tc-day-detail-loading');
      var events  = detailModal.querySelector('.hm-tc-day-detail-events');
      var title   = detailModal.querySelector('.hm-tc-day-detail-title');
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
        '<form class="hm-tc-day-event-form">' +
          '<div class="hm-tc-day-event-form-row">' +
            '<label>' + escapeHtml(fromLabel) + '</label>' +
            '<input type="date" name="starts_on" value="' + escapeHtml(absence.starts_on) + '" required>' +
          '</div>' +
          '<div class="hm-tc-day-event-form-row">' +
            '<label>' + escapeHtml(toLabel) + '</label>' +
            '<input type="date" name="ends_on" value="' + escapeHtml(absence.ends_on) + '" required>' +
          '</div>' +
          '<div class="hm-tc-day-event-form-row">' +
            '<label>' + escapeHtml(reasonLabel) + '</label>' +
            '<textarea name="reason" rows="2">' + escapeHtml(absence.reason || '') + '</textarea>' +
          '</div>' +
          '<div class="hm-tc-day-event-form-actions">' +
            '<button type="submit" class="button-positive hm-tc-day-event-form-save">' + escapeHtml(saveLabel) + '</button> ' +
            '<button type="button" class="hm-tc-day-event-form-cancel">' + escapeHtml(cancelLabel) + '</button>' +
          '</div>' +
        '</form>';

      var snapshot = li.innerHTML;
      li.innerHTML = formHtml;
      li.classList.add('hm-tc-day-event-editing');

      var form = li.querySelector('.hm-tc-day-event-form');
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        submitInlineEdit(absence, form, li, snapshot);
      });
      var cancelBtn = li.querySelector('.hm-tc-day-event-form-cancel');
      if (cancelBtn) cancelBtn.addEventListener('click', function () {
        li.innerHTML = snapshot;
        li.classList.remove('hm-tc-day-event-editing');
        rebindInlineHandlers(li, absence);
      });
    }

    function rebindInlineHandlers(li, absence) {
      var delBtn = li.querySelector('.hm-tc-day-event-delete');
      if (delBtn) {
        delBtn.addEventListener('click', function (e) {
          e.preventDefault();
          deleteAbsence(delBtn.getAttribute('data-url'), absence.kind_label);
        });
      }
      var editBtn = li.querySelector('.hm-tc-day-event-edit');
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
      body.append('hm_absence[starts_on]', fd.get('starts_on'));
      body.append('hm_absence[ends_on]',   fd.get('ends_on'));
      body.append('hm_absence[reason]',    fd.get('reason'));
      body.append('_method', 'patch');

      var saveBtn = form.querySelector('.hm-tc-day-event-form-save');
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
      var title   = detailModal.querySelector('.hm-tc-day-detail-title');
      var loading = detailModal.querySelector('.hm-tc-day-detail-loading');
      var events  = detailModal.querySelector('.hm-tc-day-detail-events');
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
          li.className = 'hm-tc-day-event hm-tc-day-event-work';
          var times = e.starts_label + ' – ' + e.ends_label;
          var net = ' (' + fmtHM(e.net_seconds) + ')';
          var html = '<strong>' + times + '</strong>' + net;
          if (e.breaks && e.breaks.length) {
            html += '<ul class="hm-tc-day-event-breaks">';
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
          li.className = 'hm-tc-day-event hm-tc-day-event-absence hm-tc-day-event-' + a.kind;
          li.dataset.absenceId = a.id;
          li.dataset.absenceKind = a.kind;
          var html = '<strong>' + escapeHtml(a.kind_label) + '</strong>';
          if (a.status && a.status !== 'approved') {
            html += ' · ' + escapeHtml(a.status_label);
          }
          if (a.starts_on !== a.ends_on) {
            html += ' · ' + a.starts_on + ' → ' + a.ends_on;
          }
          if (a.reason) html += '<div class="hm-tc-day-event-reason">' + escapeHtml(a.reason) + '</div>';
          html += '<div class="hm-tc-day-event-actions">';
          if (a.edit_url) {
            html += '<a href="#" class="icon icon-edit hm-tc-day-event-edit" title="' + escapeHtml(modalLabel('edit-label', 'Bearbeiten')) + '">' +
                    escapeHtml(modalLabel('edit-label', 'Bearbeiten')) + '</a>';
          }
          if (a.delete_url) {
            html += '<a href="#" class="icon icon-del hm-tc-day-event-delete" data-url="' + escapeHtml(a.delete_url) +
                    '" title="' + escapeHtml(modalLabel('delete-label', 'Löschen')) + '">' +
                    escapeHtml(modalLabel('delete-label', 'Löschen')) + '</a>';
          }
          html += '</div>';
          li.innerHTML = html;
          var delBtn = li.querySelector('.hm-tc-day-event-delete');
          if (delBtn) {
            delBtn.addEventListener('click', function (e) {
              e.preventDefault();
              deleteAbsence(delBtn.getAttribute('data-url'), a.kind_label);
            });
          }
          var editBtn = li.querySelector('.hm-tc-day-event-edit');
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
    }

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
      if (!window.HmTimeclockOpenAbsenceModal) return;
      window.HmTimeclockOpenAbsenceModal(starts, kindHint);
      var endEl = document.querySelector('#hm_absence_ends_on');
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
        var newBtn = e.target.closest('.hm-tc-day-detail-new');
        if (newBtn) {
          var date = detailModal.dataset.date;
          closeDetail();
          openAbsenceModalFor(date, date, newBtn.getAttribute('data-default-kind'));
        }
        if (e.target.classList.contains('hm-tc-day-detail-close') ||
            e.target.classList.contains('hm-tc-popup-close')) {
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

      cal.addEventListener('mousedown', function (e) {
        if (e.button !== 0) return;
        var cell = e.target.closest('td.hm-tc-cal-clickable[data-date]');
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
        var cell = e.target.closest('td.hm-tc-cal-clickable[data-date]');
        if (!cell) return;
        var d = cellDate(cell);
        if (d !== dragState.endDate) {
          dragState.endDate = d;
          dragState.moved = true;
          highlightRange(dragState.startDate, dragState.endDate);
        }
      });

      cal.addEventListener('contextmenu', function (e) {
        var cell = e.target.closest('td.hm-tc-cal-clickable[data-date]');
        if (!cell) return;
        e.preventDefault();
        openContextMenu(e.pageX, e.pageY, cellDate(cell));
      });

      cal.addEventListener('dblclick', function (e) {
        var cell = e.target.closest('td.hm-tc-cal-clickable[data-date]');
        if (!cell) return;
        if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
        var ids = cell.getAttribute('data-absence-ids');
        if (ids) {
          var firstId = ids.split(',')[0];
          if (firstId) window.location.href = '/hm_absences/' + firstId + '/edit';
        } else {
          openAbsenceModalFor(cellDate(cell), cellDate(cell), defaultKind);
        }
      });

      cal.addEventListener('click', function (e) {
        if (isInteractive(e.target)) return;
        var cell = e.target.closest('td.hm-tc-cal-clickable[data-date]');
        if (!cell) return;
        if (clickTimer) clearTimeout(clickTimer);
        clickTimer = setTimeout(function () {
          fetchDayDetail(cellDate(cell));
          clickTimer = null;
        }, 220);
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
    if (navLink.dataset.hmDropdownReady === '1') return;
    var bootCfg = (window.HmTimeclock && window.HmTimeclock.bootstrap) || {};
    var items = bootCfg.menuItems || [];
    if (!items.length) return;

    navLink.dataset.hmDropdownReady = '1';
    var host = navLink.closest('li') || navLink.parentNode;
    if (!host) return;
    host.classList.add('hm-hr-dropdown');

    var menu = document.createElement('ul');
    menu.className = 'hm-hr-dropdown-menu';
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
    var overtimePrefix = (snapshot.labels && snapshot.labels.overtime_prefix) || '+';
    var endStr = '';
    if (snapshot.daily_target_seconds > 0 && live.worked >= snapshot.daily_target_seconds) {
      var over = live.worked - snapshot.daily_target_seconds;
      endStr = ' ' + overtimePrefix + fmtHM(over);
    } else {
      var ee = liveExpectedEnd();
      if (ee && snapshot.daily_target_seconds > 0) {
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
        el.className = 'hm-tc-status hm-tc-status-' + snapshot.state;
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

    setupHrDropdown();
    setupAbsenceModal();
    setupCalendarInteractions();

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
