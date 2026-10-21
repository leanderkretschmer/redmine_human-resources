class HrTimeclockController < ApplicationController
  before_action :require_login
  before_action :load_target_user, only: [:show]
  before_action :load_user_setting

  helper :hr_timeclock

  def show
    user = @target_user
    tz = RedmineHumanResources::Settings.user_time_zone(user)
    today = Time.use_zone(tz) { Time.zone.today }
    @today = today
    @cal_view = %w[month week year].include?(params[:view]) ? params[:view] : 'month'
    @focus_date = parse_focus_param || today
    @week_start_day = RedmineHumanResources::Settings.first_day_of_week
    @active_kinds   = parse_kinds_param || HrAbsence::KINDS
    @month = parse_month_param || (@cal_view == 'week' ? @focus_date.beginning_of_month : today.beginning_of_month)
    case @cal_view
    when 'week'
      cal_from = @focus_date.beginning_of_week(@week_start_day)
      cal_to   = @focus_date.end_of_week(@week_start_day)
    when 'year'
      cal_from = Date.new(@focus_date.year, 1, 1)
      cal_to   = Date.new(@focus_date.year, 12, 31)
    else
      cal_from = @month
      cal_to   = @month.end_of_month
    end
    @entries_today = HrWorkEntry.for_user(user).on_day(tz, today).order(:started_at).to_a
    @entries_month = HrWorkEntry.for_user(user)
                                .in_range(cal_from.in_time_zone(tz).beginning_of_day,
                                          cal_to.in_time_zone(tz).end_of_day)
                                .order(:started_at).to_a
    overlay = HrAbsence.for_user(user).active.overlapping(cal_from, cal_to).to_a
    @absences_by_day = HrAbsence.build_by_day(overlay, cal_from, cal_to)
    @lecture_periods = HrLecturePeriod.for_user(user)
                                      .where('starts_on <= ? AND ends_on >= ?', cal_to, cal_from)
                                      .to_a
    @monthly_plan    = HrMonthlyPlan.for_user(user).for_period(@month.year, @month.month).first
    @holidays_by_day = compute_personal_holidays_range(user, cal_from, cal_to)
    # Snapshot (laufende Session, Start/Stop-Buttons) nur fuer den echten
    # eigenen Account — ein Admin, der eine fremde Session impersonaten
    # wuerde, saehe nur Fremddaten und koennte dort fremde Shifts starten/
    # stoppen. Beim Impersonate darum ohne Snapshot rendern.
    @snapshot = @impersonating ? nil : build_snapshot

    # Full-set der Impersonate-Liste (nur HR-Nutzer, nicht User.current).
    @impersonate_candidates = admin_impersonate_candidates if User.current.admin?

    # Year-to-date sickness aggregation for the personal KPI tile.
    @sickness_summary  = HrAbsence.sickness_summary(user, today.year)
    @vacation_summary  = HrAbsence.vacation_remaining(user, today.year)

    # "Arbeit diese Woche" — net seconds across the current ISO week, honours
    # the configured first-day-of-week.
    week_start = today.beginning_of_week(@week_start_day)
    week_end   = today.end_of_week(@week_start_day)
    week_entries = HrWorkEntry.for_user(user)
                              .in_range(week_start.in_time_zone(tz).beginning_of_day,
                                        week_end.in_time_zone(tz).end_of_day).to_a
    @worked_this_week = week_entries.sum { |e| e.net_seconds }.to_i

    # "Geplante Arbeitszeit" (Werkstudent/Intern) — count self-booked WORKDAY
    # absences inside the current month: partial-time entries count their
    # explicit window, full-day entries fall back to the user's base daily
    # target. Compared against the monthly plan's target_minutes.
    if @user_setting.allows_monthly_plan?
      month_start = today.beginning_of_month
      month_end   = today.end_of_month
      planned_workdays = HrAbsence.for_user(user).active
                                  .where(kind: HrAbsence::KIND_WORKDAY)
                                  .where('starts_on <= ? AND ends_on >= ?', month_end, month_start)
                                  .to_a
      planned_min = planned_workdays.sum do |a|
        (a.starts_on..a.ends_on).sum do |d|
          next 0 unless d >= month_start && d <= month_end
          if a.partial? && a.starts_on == d && a.ends_on == d
            a.partial_minutes_on(d)
          else
            @user_setting.base_daily_target_minutes(on_date: d)
          end
        end
      end
      target_min = @monthly_plan ? @monthly_plan.target_minutes.to_i :
                                   @user_setting.effective_weekly_target_minutes(on_date: today).to_i * 4
      @planned_workday_summary = {
        planned_secs: planned_min.to_i * 60,
        target_secs:  target_min.to_i  * 60,
        percent: target_min.to_i.positive? ? [(planned_min.to_f / target_min * 100).round, 100].min : 0
      }
    end

    @chart_view = %w[today week month].include?(params[:chart_view]) ? params[:chart_view] : 'today'
    chart_from, chart_to = case @chart_view
                            when 'week'  then [today.beginning_of_week, today.end_of_week]
                            when 'month' then [today.beginning_of_month, today.end_of_month]
                            else              [today, today]
                            end
    @chart_metrics = compute_personal_chart_metrics(user, chart_from, chart_to, tz)
  end

  def status
    respond_to do |format|
      format.json { render json: build_snapshot }
    end
  end

  def calendar
    tz = User.current.time_zone || Time.zone
    @month = parse_month_param || Date.current.beginning_of_month
    @entries_month = HrWorkEntry.for_user(User.current)
                                .in_range(@month.in_time_zone(tz).beginning_of_day,
                                          @month.end_of_month.in_time_zone(tz).end_of_day)
                                .order(:started_at).to_a
    respond_to do |format|
      format.html
      format.json { render json: calendar_payload }
    end
  end

  def edit_settings
  end

  def update_settings
    permitted = setting_params
    @user_setting.assign_attributes(permitted)
    if @user_setting.save
      flash[:notice] = l(:notice_hr_timeclock_settings_saved)
      respond_to do |format|
        format.html { redirect_to hr_timeclock_path }
        format.json { render json: build_snapshot }
      end
    else
      respond_to do |format|
        format.html { render :edit_settings }
        format.json { render json: { errors: @user_setting.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def start
    open = current_open_entry
    if open && open.overdue?(as_of: Time.current)
      flash[:error] = l(:notice_hr_timeclock_resolve_correction_first)
      return redirect_to hr_timeclock_path
    end
    unless open
      HrWorkEntry.create!(
        user_id:    User.current.id,
        started_at: Time.current,
        state:      HrWorkEntry::STATE_RUNNING,
        created_ip: request.remote_ip
      )
    end
    respond_action(l(:notice_hr_timeclock_started))
  end

  def pause
    entry = current_open_entry
    return respond_action(nil) if entry && entry.overdue?(as_of: Time.current)
    if entry && entry.running?
      HrWorkEntry.transaction do
        HrBreakEntry.create!(hr_work_entry_id: entry.id, started_at: Time.current)
        entry.update!(state: HrWorkEntry::STATE_PAUSED)
      end
    end
    respond_action(l(:notice_hr_timeclock_paused))
  end

  def resume
    entry = current_open_entry
    return respond_action(nil) if entry && entry.overdue?(as_of: Time.current)
    if entry && entry.paused?
      HrWorkEntry.transaction do
        brk = entry.current_break
        brk&.update!(ended_at: Time.current)
        entry.update!(state: HrWorkEntry::STATE_RUNNING)
      end
    end
    respond_action(l(:notice_hr_timeclock_resumed))
  end

  def stop
    entry = current_open_entry
    return respond_action(nil) if entry && entry.overdue?(as_of: Time.current)
    if entry
      HrWorkEntry.transaction do
        brk = entry.current_break
        brk&.update!(ended_at: Time.current)
        entry.update!(state: HrWorkEntry::STATE_COMPLETED, ended_at: Time.current)
      end
    end
    respond_action(l(:notice_hr_timeclock_stopped))
  end

  def export
    tz = User.current.time_zone || Time.zone
    month = parse_month_param || Date.current.beginning_of_month
    entries = HrWorkEntry.for_user(User.current)
                         .in_range(month.in_time_zone(tz).beginning_of_day,
                                   month.end_of_month.in_time_zone(tz).end_of_day)
                         .order(:started_at).to_a
    send_data HrWorkEntry.to_csv(User.current, entries),
              filename: "hr_timeclock_#{User.current.login}_#{month.strftime('%Y-%m')}.csv",
              type: 'text/csv; charset=utf-8'
  end

  # Pre-stop preview: everything the stop popup needs — today's net work,
  # breaks, booked TimeEntries grouped per issue, free-text entries, resulting
  # coverage share, and the end-of-day message when this user is the last one
  # still clocked in. Pure JSON.
  def stop_preview
    render json: build_stop_preview_payload
  end

  # Autocomplete source for the ticket picker inside the stop popup.
  # Honours Redmine's visibility rules — queries go through Issue.visible so a
  # user never sees issues from projects they cannot access.
  def issue_search
    q = params[:q].to_s.strip
    results = []
    if q.length >= 1
      scope = Issue.visible.includes(:project).order(updated_on: :desc)
      scope = if q.match?(/\A\d+\z/)
                scope.where('issues.id = ? OR issues.subject LIKE ?', q.to_i, "%#{q}%")
              else
                scope.where('issues.subject LIKE ?', "%#{q}%")
              end
      results = scope.limit(15).map do |iss|
        {
          id:      iss.id,
          subject: iss.subject,
          project: iss.project&.name,
          label:   "##{iss.id} #{iss.subject}" + (iss.project ? " · #{iss.project.name}" : '')
        }
      end
    end
    render json: { results: results }
  end

  # Create a new coverage entry attached to today. kind=ticket writes a real
  # Redmine TimeEntry so it shows up in the issue's time log; kind=freetext
  # stays inside the plugin as an HrFreeEntry (counts toward "other coverage"
  # for the bar, not toward ticket coverage).
  def create_coverage_entry
    kind = params[:kind].to_s
    seconds = params[:seconds].to_i
    return render json: { error: 'invalid_seconds' }, status: :bad_request if seconds <= 0

    tz = RedmineHumanResources::Settings.user_time_zone(User.current)
    today = Time.use_zone(tz) { Time.zone.today }

    case kind
    when 'ticket'
      issue = Issue.visible.find_by(id: params[:issue_id])
      return render json: { error: 'issue_not_found' }, status: :not_found unless issue
      activity = TimeEntryActivity.default || TimeEntryActivity.active.first
      return render json: { error: 'no_activity' }, status: :unprocessable_entity unless activity
      hours = (seconds / 3600.0).round(4)
      te = TimeEntry.new(
        user:     User.current,
        author:   User.current,
        project:  issue.project,
        issue:    issue,
        spent_on: today,
        hours:    hours,
        comments: params[:comments].to_s[0, 255],
        activity: activity
      )
      if te.save
        render json: time_entry_payload(te)
      else
        render json: { error: te.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    when 'freetext'
      note = params[:note].to_s.strip
      return render json: { error: 'note_required' }, status: :bad_request if note.empty?
      fe = HrFreeEntry.new(user: User.current, spent_on: today,
                           seconds: seconds, note: note[0, 500])
      if fe.save
        render json: free_entry_payload(fe)
      else
        render json: { error: fe.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    else
      render json: { error: 'invalid_kind' }, status: :bad_request
    end
  end

  # Edit an existing coverage entry's duration (and comment / note). Only the
  # entry's owner can touch it, admins may edit anyone's.
  def update_coverage_entry
    kind = params[:kind].to_s
    seconds = params[:seconds].to_i
    return render json: { error: 'invalid_seconds' }, status: :bad_request if seconds <= 0

    case kind
    when 'ticket'
      te = TimeEntry.find_by(id: params[:id])
      return render json: { error: 'not_found' }, status: :not_found unless te
      return render json: { error: 'forbidden' }, status: :forbidden unless te.user_id == User.current.id || User.current.admin?
      te.hours    = (seconds / 3600.0).round(4)
      te.comments = params[:comments].to_s[0, 255] if params.key?(:comments)
      if te.save
        render json: time_entry_payload(te)
      else
        render json: { error: te.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    when 'freetext'
      fe = HrFreeEntry.find_by(id: params[:id])
      return render json: { error: 'not_found' }, status: :not_found unless fe
      return render json: { error: 'forbidden' }, status: :forbidden unless fe.user_id == User.current.id || User.current.admin?
      fe.seconds = seconds
      fe.note    = params[:note].to_s[0, 500] if params.key?(:note)
      if fe.save
        render json: free_entry_payload(fe)
      else
        render json: { error: fe.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    else
      render json: { error: 'invalid_kind' }, status: :bad_request
    end
  end

  def delete_coverage_entry
    kind = params[:kind].to_s
    case kind
    when 'ticket'
      te = TimeEntry.find_by(id: params[:id])
      return render json: { error: 'not_found' }, status: :not_found unless te
      return render json: { error: 'forbidden' }, status: :forbidden unless te.user_id == User.current.id || User.current.admin?
      te.destroy
      render json: { ok: true }
    when 'freetext'
      fe = HrFreeEntry.find_by(id: params[:id])
      return render json: { error: 'not_found' }, status: :not_found unless fe
      return render json: { error: 'forbidden' }, status: :forbidden unless fe.user_id == User.current.id || User.current.admin?
      fe.destroy
      render json: { ok: true }
    else
      render json: { error: 'invalid_kind' }, status: :bad_request
    end
  end

  def day_detail
    tz = User.current.time_zone || Time.zone
    date = Date.parse(params[:date])
    range_from = date.in_time_zone(tz).beginning_of_day
    range_to   = date.in_time_zone(tz).end_of_day
    entries = HrWorkEntry.for_user(User.current).in_range(range_from, range_to).order(:started_at).to_a
    absences = HrAbsence.for_user(User.current)
                        .where('starts_on <= ? AND ends_on >= ?', date, date)
                        .order(:starts_on).to_a
    render json: build_day_payload(date, entries, absences, tz)
  rescue ArgumentError
    render json: { error: 'invalid_date' }, status: :bad_request
  end

  # ── Self-service correction of an already-closed entry ───────────────────
  # Users may propose new start/end times on their own completed entries;
  # the request waits in state 'requested' until an admin signs it off.
  def propose_correction
    entry = HrWorkEntry.for_user(User.current).where(id: params[:id]).first
    return redirect_to(hr_timeclock_path, alert: l(:notice_hr_correction_not_found)) unless entry
    if entry.open?
      flash[:error] = l(:notice_hr_correction_open_entry)
      return redirect_to(hr_timeclock_path)
    end

    tz = RedmineHumanResources::Settings.user_time_zone(User.current)
    new_start = parse_local_datetime(params[:started_at].to_s, tz, entry.started_at)
    new_end   = parse_local_datetime(params[:ended_at].to_s,   tz, entry.ended_at)
    unless new_start && new_end && new_end > new_start
      flash[:error] = l(:notice_hr_correction_invalid_times)
      return redirect_to(hr_timeclock_path)
    end

    entry.propose_correction!(
      new_started_at: new_start,
      new_ended_at:   new_end,
      reason: params[:reason].to_s
    )
    flash[:notice] = l(:notice_hr_correction_submitted)
    redirect_back(fallback_location: hr_timeclock_path)
  rescue ArgumentError => e
    flash[:error] = e.message
    redirect_to hr_timeclock_path
  end

  def approve_correction
    return head(:forbidden) unless User.current.admin?
    entry = HrWorkEntry.where(id: params[:id]).first
    return redirect_to(hr_admin_path, alert: l(:notice_hr_correction_not_found)) unless entry
    entry.approve_correction!(by_user: User.current)
    flash[:notice] = l(:notice_hr_correction_approved)
    redirect_back(fallback_location: hr_admin_path)
  end

  def reject_correction
    return head(:forbidden) unless User.current.admin?
    entry = HrWorkEntry.where(id: params[:id]).first
    return redirect_to(hr_admin_path, alert: l(:notice_hr_correction_not_found)) unless entry
    entry.reject_correction!(by_user: User.current, note: params[:note])
    flash[:notice] = l(:notice_hr_correction_rejected)
    redirect_back(fallback_location: hr_admin_path)
  end

  def correct
    entry = HrWorkEntry.for_user(User.current).where(id: params[:id]).first
    unless entry && entry.open? && entry.overdue?(as_of: Time.current)
      flash[:error] = l(:notice_hr_timeclock_correction_invalid)
      return redirect_to hr_timeclock_path
    end

    tz = User.current.time_zone || Time.zone
    ended_at = parse_correction_time(entry, params[:ended_at].to_s, tz)

    if ended_at.nil?
      flash[:error] = l(:notice_hr_timeclock_correction_invalid)
      return redirect_to hr_timeclock_path
    end

    HrWorkEntry.transaction do
      if (brk = entry.current_break)
        brk_end = ended_at < brk.started_at ? brk.started_at : ended_at
        brk.update!(ended_at: brk_end)
      end
      addition = "[Korrektur] geschlossen am #{Time.current.iso8601} durch #{User.current.login} (Original blieb offen)."
      new_notes = [entry.notes.presence, addition].compact.join("\n")
      entry.update!(ended_at: ended_at,
                    state: HrWorkEntry::STATE_COMPLETED,
                    notes: new_notes)
    end

    flash[:notice] = l(:notice_hr_timeclock_correction_saved)
    redirect_to hr_timeclock_path
  end

  private

  # Admin-only "als anderer Nutzer anzeigen" via ?impersonate_user_id=X.
  # Faellt auf User.current zurueck, wenn kein Admin oder kein gueltiger
  # Parameter (so dass Start/Stop und Snapshot-Logik unveraendert laufen).
  def load_target_user
    @target_user = User.current
    @impersonating = false
    uid = params[:impersonate_user_id].to_s
    return if uid.blank?
    return unless User.current.admin?
    candidate = User.active.where.not(type: 'AnonymousUser').find_by(id: uid)
    return unless candidate
    @target_user = candidate
    @impersonating = (candidate.id != User.current.id)
  end

  def admin_impersonate_candidates
    hr_user_ids = (HrWorkEntry.distinct.pluck(:user_id) +
                   HrAbsence.distinct.pluck(:user_id)).uniq
    return [] if hr_user_ids.empty?
    User.active.where(id: hr_user_ids)
        .where.not(type: 'AnonymousUser')
        .where.not(id: User.current.id)
        .sorted
        .pluck(:firstname, :lastname, :login, :id)
  end

  def load_user_setting
    target = @target_user || User.current
    @user_setting = HrUserSetting.for(target)
    @user_setting.save!(validate: false) if @user_setting.new_record?
  end

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
  rescue ArgumentError
    nil
  end

  def current_open_entry
    HrWorkEntry.for_user(User.current).open.order(started_at: :desc).first
  end

  def respond_action(message)
    respond_to do |format|
      format.html do
        flash[:notice] = message if message.present?
        redirect_to hr_timeclock_path
      end
      format.json { render json: build_snapshot }
    end
  end

  def build_snapshot
    RedmineHumanResources::Snapshot.new(User.current, @user_setting).to_h
  end

  # Holiday lookup for the personal calendar. Returns a hash
  # { Date => [{ name:, regions: }, …] }. When the user has no region set we
  # still show the federal (bundesweit) holidays — better than a silently
  # empty calendar.
  def compute_personal_holidays_range(user, range_from, range_to)
    setting = HrUserSetting.for(user)
    region  = setting.effective_region_code.presence
    year_maps = {}
    out = {}
    (range_from..range_to).each do |d|
      map = (year_maps[d.year] ||= RedmineHumanResources::Holidays.holidays_for(d.year, region_code: region))
      name = map[d]
      out[d] = [{ name: name, regions: region ? [region] : [] }] if name
    end
    out
  rescue StandardError => e
    Rails.logger.warn("[hr] personal holiday lookup failed: #{e.message}") if defined?(Rails)
    {}
  end

  def parse_focus_param
    return nil unless params[:focus].present?
    Date.parse(params[:focus].to_s)
  rescue ArgumentError
    nil
  end

  def parse_kinds_param
    raw = params[:kinds]
    return nil if raw.blank?
    list = raw.to_s.split(',').map(&:strip) & HrAbsence::KINDS
    list.empty? ? [] : list
  end

  def compute_personal_chart_metrics(user, range_from, range_to, tz)
    entries = HrWorkEntry.for_user(user)
                         .in_range(range_from.in_time_zone(tz).beginning_of_day,
                                   range_to.in_time_zone(tz).end_of_day).to_a
    now = Time.current
    work_secs  = entries.sum { |e| e.net_seconds(as_of: now) }
    break_secs = entries.sum { |e| e.total_break_seconds(as_of: now) }
    coverage_h = TimeEntry.where(user_id: user.id, spent_on: range_from..range_to).sum(:hours).to_f
    { work: work_secs.to_i, break_secs: break_secs.to_i, coverage: (coverage_h * 3600).round }
  rescue StandardError => e
    Rails.logger.warn("[hr] compute_personal_chart_metrics failed: #{e.message}")
    { work: 0, break_secs: 0, coverage: 0 }
  end

  def calendar_payload
    tz = User.current.time_zone || Time.zone
    days = (@month..@month.end_of_month).map do |d|
      total = HrWorkEntry.for_user(User.current).on_day(tz, d).to_a.sum { |e| e.net_seconds }
      { date: d.iso8601, seconds: total }
    end
    { month: @month.iso8601, days: days }
  end

  def setting_params
    raw = params[:hr_user_setting] || ActionController::Parameters.new
    attrs = raw.permit(:daily_target_minutes, :weekly_target_minutes, :max_break_minutes,
                       :daily_target_hours, :weekly_target_hours, :max_break_hours,
                       :notify_target_reached, :notify_break_over).to_h

    { daily_target_hours: :daily_target_minutes,
      weekly_target_hours: :weekly_target_minutes,
      max_break_hours: :max_break_minutes }.each do |hour_key, min_key|
      hour_val = attrs.delete(hour_key.to_s) || attrs.delete(hour_key)
      next if hour_val.nil?
      attrs[min_key.to_s] = hour_val.to_s.strip.empty? ? nil : (hour_val.to_f * 60).round
    end

    attrs
  end

  def build_day_payload(date, entries, absences, tz)
    events = []
    entries.each do |e|
      effective_end = e.effective_end_at(as_of: Time.current) || Time.current
      events << {
        type: 'work',
        id: e.id,
        starts_at_unix: e.started_at.to_i,
        ends_at_unix: effective_end.to_i,
        starts_label: e.started_at.in_time_zone(tz).strftime('%H:%M'),
        ends_label:   e.ended_at ? e.ended_at.in_time_zone(tz).strftime('%H:%M') : '—',
        net_seconds:  e.net_seconds(as_of: Time.current),
        state: e.state,
        breaks: e.hr_break_entries.order(:started_at).map do |b|
          {
            starts_at_unix: b.started_at.to_i,
            ends_at_unix:   b.ended_at&.to_i,
            starts_label:   b.started_at.in_time_zone(tz).strftime('%H:%M'),
            ends_label:     b.ended_at ? b.ended_at.in_time_zone(tz).strftime('%H:%M') : '—',
            seconds:        (b.ended_at || Time.current).to_i - b.started_at.to_i
          }
        end
      }
    end
    absence_events = absences.map do |a|
      # Owner may always remove an entry that lies in the future, plus every
      # self-service kind regardless of status. Approved past vacation stays
      # admin-only (that's HR-tracked). Admin may touch anything.
      can_manage = User.current.admin? ||
                   (a.user_id == User.current.id &&
                    (a.starts_on >= Date.current ||
                     a.workday? || a.homeoffice? || a.care? ||
                     a.sickness? || a.offsite? || a.school? || a.blocked? ||
                     a.requested?))
      {
        type: 'absence',
        id: a.id,
        kind: a.kind,
        kind_label: HrAbsence.kind_label(a.kind),
        status: a.status,
        status_label: HrAbsence.status_label(a.status),
        reason: a.reason,
        starts_on: a.starts_on.iso8601,
        ends_on:   a.ends_on.iso8601,
        start_time: a.start_time,
        end_time:   a.end_time,
        partial:    a.partial?,
        partial_minutes: a.partial_minutes_on(date),
        can_manage: can_manage,
        edit_url:   can_manage ? edit_hr_absence_path(a, format: nil) : nil,
        delete_url: can_manage ? hr_absence_path(a, format: nil)      : nil
      }
    end
    {
      date: date.iso8601,
      date_label: I18n.l(date, format: :long),
      events: events,
      absences: absence_events
    }
  end

  # Accept a `<input type="datetime-local">` payload (YYYY-MM-DDTHH:MM) or any
  # parseable timestamp, interpreted in the user's own time zone.
  def parse_local_datetime(str, tz, fallback = nil)
    return fallback if str.blank?
    Time.use_zone(tz) { Time.zone.parse(str) }
  rescue ArgumentError
    fallback
  end

  def build_stop_preview_payload
    user = User.current
    tz = RedmineHumanResources::Settings.user_time_zone(user)
    today = Time.use_zone(tz) { Time.zone.today }
    now = Time.current

    entries = HrWorkEntry.for_user(user).on_day(tz, today).to_a
    worked_seconds   = entries.sum { |e| e.net_seconds(as_of: now) }
    break_seconds    = entries.sum { |e| e.total_break_seconds(as_of: now) }

    time_entries = TimeEntry.where(user_id: user.id, spent_on: today..today)
                            .includes(:issue, :project, :activity)
                            .order(:id).to_a
    ticket_payload = time_entries.map { |te| time_entry_payload(te) }
    ticket_seconds = ticket_payload.sum { |t| t[:seconds].to_i }

    free_entries = HrFreeEntry.for_user(user).on_day(today).order(:id).to_a
    free_payload = free_entries.map { |fe| free_entry_payload(fe) }
    free_seconds = free_payload.sum { |f| f[:seconds].to_i }

    covered = ticket_seconds + free_seconds
    coverage_pct = worked_seconds.positive? ? ((covered.to_f / worked_seconds) * 100).round(1) : 0.0

    is_last_user = other_open_users?(tz, today) == false
    eod_msg = Setting.plugin_redmine_human_resources['end_of_day_message'].to_s.strip

    {
      state:               current_open_entry ? (current_open_entry.paused? ? 'on_break' : 'working') : 'idle',
      worked_seconds:      worked_seconds,
      break_seconds:       break_seconds,
      ticket_seconds:      ticket_seconds,
      free_seconds:        free_seconds,
      coverage_percent:    coverage_pct,
      coverage_target_sec: worked_seconds,
      ticket_entries:      ticket_payload,
      free_entries:        free_payload,
      is_last_user:        is_last_user,
      end_of_day_message:  (is_last_user && eod_msg.present? ? eod_msg : nil),
      today:               today.iso8601
    }
  end

  def time_entry_payload(te)
    seconds = (te.hours.to_f * 3600).round
    {
      kind:          'ticket',
      id:            te.id,
      issue_id:      te.issue_id,
      issue_label:   te.issue ? "##{te.issue.id} #{te.issue.subject}" : nil,
      project_name:  te.project&.name,
      activity_name: te.activity&.name,
      comments:      te.comments.to_s,
      seconds:       seconds
    }
  end

  def free_entry_payload(fe)
    {
      kind:    'freetext',
      id:      fe.id,
      note:    fe.note.to_s,
      seconds: fe.seconds.to_i
    }
  end

  # Checks whether any other user still has an open (running or paused) shift
  # today. True → someone else is still clocked in, so the current user is NOT
  # the last one leaving.
  def other_open_users?(tz, today)
    HrWorkEntry.open
               .where.not(user_id: User.current.id)
               .where(started_at: today.in_time_zone(tz).beginning_of_day..today.in_time_zone(tz).end_of_day)
               .exists?
  end

  def parse_correction_time(entry, str, tz)
    return nil if str.blank?
    started_day = entry.started_at.in_time_zone(tz).to_date

    parsed =
      if str.match?(/\A\d{1,2}:\d{2}\z/)
        # Bare HH:MM — assume the start day; if that lands before the start
        # time, roll over to the next day (night shift past midnight).
        h, m = str.split(':').map(&:to_i)
        candidate = Time.use_zone(tz) { Time.zone.local(started_day.year, started_day.month, started_day.day, h, m) }
        candidate <= entry.started_at ? candidate + 1.day : candidate
      else
        # datetime-local ("YYYY-MM-DDTHH:MM") or any parseable timestamp.
        Time.use_zone(tz) { Time.zone.parse(str) } rescue nil
      end

    return nil unless parsed
    return nil if parsed <= entry.started_at
    return nil if parsed > Time.current + 1.minute
    parsed
  end
end
