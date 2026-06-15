class HmTimeclockController < ApplicationController
  before_action :require_login
  before_action :load_user_setting

  helper :hm_timeclock

  def show
    tz = User.current.time_zone || Time.zone
    today = Time.use_zone(tz) { Time.zone.today }
    @today = today
    @month = parse_month_param || today.beginning_of_month
    @entries_today = HmWorkEntry.for_user(User.current).on_day(tz, today).order(:started_at).to_a
    @entries_month = HmWorkEntry.for_user(User.current)
                                .in_range(@month.in_time_zone(tz).beginning_of_day,
                                          @month.end_of_month.in_time_zone(tz).end_of_day)
                                .order(:started_at).to_a
    overlay = HmAbsence.for_user(User.current).active.overlapping(@month, @month.end_of_month).to_a
    @absences_by_day = HmAbsence.build_by_day(overlay, @month, @month.end_of_month)
    @lecture_periods = HmLecturePeriod.for_user(User.current)
                                      .where('starts_on <= ? AND ends_on >= ?', @month.end_of_month, @month)
                                      .to_a
    @monthly_plan    = HmMonthlyPlan.for_user(User.current).for_period(@month.year, @month.month).first
    @holidays_by_day = compute_personal_holidays(User.current, @month)
    @snapshot = build_snapshot

    @chart_view = %w[today week month].include?(params[:chart_view]) ? params[:chart_view] : 'today'
    chart_from, chart_to = case @chart_view
                            when 'week'  then [today.beginning_of_week, today.end_of_week]
                            when 'month' then [today.beginning_of_month, today.end_of_month]
                            else              [today, today]
                            end
    @chart_metrics = compute_personal_chart_metrics(User.current, chart_from, chart_to, tz)
  end

  def status
    respond_to do |format|
      format.json { render json: build_snapshot }
    end
  end

  def calendar
    tz = User.current.time_zone || Time.zone
    @month = parse_month_param || Date.current.beginning_of_month
    @entries_month = HmWorkEntry.for_user(User.current)
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
      flash[:notice] = l(:notice_hm_timeclock_settings_saved)
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
      flash[:error] = l(:notice_hm_timeclock_resolve_correction_first)
      return redirect_to hr_timeclock_path
    end
    unless open
      HmWorkEntry.create!(
        user_id:    User.current.id,
        started_at: Time.current,
        state:      HmWorkEntry::STATE_RUNNING,
        created_ip: request.remote_ip
      )
    end
    respond_action(l(:notice_hm_timeclock_started))
  end

  def pause
    entry = current_open_entry
    return respond_action(nil) if entry && entry.overdue?(as_of: Time.current)
    if entry && entry.running?
      HmWorkEntry.transaction do
        HmBreakEntry.create!(hm_work_entry_id: entry.id, started_at: Time.current)
        entry.update!(state: HmWorkEntry::STATE_PAUSED)
      end
    end
    respond_action(l(:notice_hm_timeclock_paused))
  end

  def resume
    entry = current_open_entry
    return respond_action(nil) if entry && entry.overdue?(as_of: Time.current)
    if entry && entry.paused?
      HmWorkEntry.transaction do
        brk = entry.current_break
        brk&.update!(ended_at: Time.current)
        entry.update!(state: HmWorkEntry::STATE_RUNNING)
      end
    end
    respond_action(l(:notice_hm_timeclock_resumed))
  end

  def stop
    entry = current_open_entry
    return respond_action(nil) if entry && entry.overdue?(as_of: Time.current)
    if entry
      HmWorkEntry.transaction do
        brk = entry.current_break
        brk&.update!(ended_at: Time.current)
        entry.update!(state: HmWorkEntry::STATE_COMPLETED, ended_at: Time.current)
      end
    end
    respond_action(l(:notice_hm_timeclock_stopped))
  end

  def export
    tz = User.current.time_zone || Time.zone
    month = parse_month_param || Date.current.beginning_of_month
    entries = HmWorkEntry.for_user(User.current)
                         .in_range(month.in_time_zone(tz).beginning_of_day,
                                   month.end_of_month.in_time_zone(tz).end_of_day)
                         .order(:started_at).to_a
    send_data HmWorkEntry.to_csv(User.current, entries),
              filename: "hm_timeclock_#{User.current.login}_#{month.strftime('%Y-%m')}.csv",
              type: 'text/csv; charset=utf-8'
  end

  def day_detail
    tz = User.current.time_zone || Time.zone
    date = Date.parse(params[:date])
    range_from = date.in_time_zone(tz).beginning_of_day
    range_to   = date.in_time_zone(tz).end_of_day
    entries = HmWorkEntry.for_user(User.current).in_range(range_from, range_to).order(:started_at).to_a
    absences = HmAbsence.for_user(User.current)
                        .where('starts_on <= ? AND ends_on >= ?', date, date)
                        .order(:starts_on).to_a
    render json: build_day_payload(date, entries, absences, tz)
  rescue ArgumentError
    render json: { error: 'invalid_date' }, status: :bad_request
  end

  def correct
    entry = HmWorkEntry.for_user(User.current).where(id: params[:id]).first
    unless entry && entry.open? && entry.overdue?(as_of: Time.current)
      flash[:error] = l(:notice_hm_timeclock_correction_invalid)
      return redirect_to hr_timeclock_path
    end

    tz = User.current.time_zone || Time.zone
    ended_at = parse_correction_time(entry, params[:ended_at].to_s, tz)

    if ended_at.nil?
      flash[:error] = l(:notice_hm_timeclock_correction_invalid)
      return redirect_to hr_timeclock_path
    end

    HmWorkEntry.transaction do
      if (brk = entry.current_break)
        brk_end = ended_at < brk.started_at ? brk.started_at : ended_at
        brk.update!(ended_at: brk_end)
      end
      addition = "[Korrektur] geschlossen am #{Time.current.iso8601} durch #{User.current.login} (Original blieb offen)."
      new_notes = [entry.notes.presence, addition].compact.join("\n")
      entry.update!(ended_at: ended_at,
                    state: HmWorkEntry::STATE_COMPLETED,
                    notes: new_notes)
    end

    flash[:notice] = l(:notice_hm_timeclock_correction_saved)
    redirect_to hr_timeclock_path
  end

  private

  def load_user_setting
    @user_setting = HmUserSetting.for(User.current)
    @user_setting.save!(validate: false) if @user_setting.new_record?
  end

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
  rescue ArgumentError
    nil
  end

  def current_open_entry
    HmWorkEntry.for_user(User.current).open.order(started_at: :desc).first
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
  def compute_personal_holidays(user, month_start)
    setting = HmUserSetting.for(user)
    region  = setting.effective_region_code.presence
    range_from = month_start
    range_to   = month_start.end_of_month
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

  def compute_personal_chart_metrics(user, range_from, range_to, tz)
    entries = HmWorkEntry.for_user(user)
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
      total = HmWorkEntry.for_user(User.current).on_day(tz, d).to_a.sum { |e| e.net_seconds }
      { date: d.iso8601, seconds: total }
    end
    { month: @month.iso8601, days: days }
  end

  def setting_params
    raw = params[:hm_user_setting] || ActionController::Parameters.new
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
        breaks: e.hm_break_entries.order(:started_at).map do |b|
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
      can_manage = User.current.admin? || (a.user_id == User.current.id && (a.requested? || a.sickness? || a.offsite? || a.school? || a.blocked?))
      {
        type: 'absence',
        id: a.id,
        kind: a.kind,
        kind_label: HmAbsence.kind_label(a.kind),
        status: a.status,
        status_label: HmAbsence.status_label(a.status),
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
