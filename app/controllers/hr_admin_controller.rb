class HrAdminController < ApplicationController
  before_action :require_admin

  helper :hr_timeclock

  def index
    today = Date.current
    @cal_view = %w[month week].include?(params[:view]) ? params[:view] : 'month'
    @focus_date = parse_admin_focus_param || today
    @month = parse_month_param || (@cal_view == 'week' ? @focus_date.beginning_of_month : today.beginning_of_month)

    base_user_ids = (HrWorkEntry.distinct.pluck(:user_id) + HrAbsence.distinct.pluck(:user_id)).uniq
    relation = User.where(id: base_user_ids)

    @filter_name = params[:filter_name].to_s.strip
    if @filter_name.present?
      n = "%#{@filter_name.downcase}%"
      relation = relation.where('LOWER(firstname) LIKE :n OR LOWER(lastname) LIKE :n OR LOWER(login) LIKE :n', n: n)
    end
    all_users = relation.sorted.to_a
    @summaries = all_users.each_with_object({}) { |u, h| h[u.id] = compute_summary(u) }
    all_users.sort_by! { |u| -(@summaries[u.id][:month].to_i) }

    if @cal_view == 'week'
      cal_from = @focus_date.beginning_of_week
      cal_to   = @focus_date.end_of_week
    else
      cal_from = @month
      cal_to   = @month.end_of_month
    end
    overlay = HrAbsence.active.overlapping(cal_from, cal_to).includes(:user).to_a
    @absences_by_day = HrAbsence.build_by_day(overlay, cal_from, cal_to)
    @holidays_by_day = compute_global_holidays(all_users, cal_from, cal_to)
    @lecture_periods = HrLecturePeriod.where(user_id: all_users.map(&:id))
                                      .where('starts_on <= ? AND ends_on >= ?', cal_to, cal_from)
                                      .includes(:user).to_a
    @week_entries = if @cal_view == 'week'
                      HrWorkEntry.where(user_id: all_users.map(&:id))
                                 .in_range(cal_from.beginning_of_day, cal_to.end_of_day)
                                 .includes(:user).to_a
                    else
                      []
                    end
    @pending_absences = HrAbsence.pending.includes(:user, :approver).order(:starts_on).limit(100).to_a

    # ── Dashboard KPIs (across the full filtered set, all pages) ──
    today = Date.current
    absent_today = HrAbsence.active.where('starts_on <= ? AND ends_on >= ?', today, today).distinct.pluck(:user_id)
    @kpi = {
      worked_month:        all_users.sum { |u| @summaries[u.id][:month].to_i },
      worked_today:        all_users.sum { |u| @summaries[u.id][:today].to_i },
      planned_today_secs:  planned_today_seconds(all_users, today),
      pending:             @pending_absences.size,
      absent_today:        (absent_today & all_users.map(&:id)).size
    }
    # ── Bar chart view-range toggle (today / week / month, default today) ──
    @chart_view = %w[today week month].include?(params[:chart_view]) ? params[:chart_view] : 'today'
    chart_from, chart_to = case @chart_view
                            when 'week'  then [today.beginning_of_week, today.end_of_week]
                            when 'month' then [today.beginning_of_month, today.end_of_month]
                            else              [today, today]
                            end

    # ── Pagination of the employee list (10/page) ──
    per_page = 10
    @user_count = all_users.size
    @paginator = Redmine::Pagination::Paginator.new(@user_count, per_page, params[:page])
    page_users = all_users[@paginator.offset, @paginator.per_page] || []
    @chart_rows = page_users.map do |u|
      m = compute_chart_metrics(u, chart_from, chart_to)
      { user: u, work: m[:work], break_secs: m[:break_secs], coverage: m[:coverage],
        last_entry: @summaries[u.id][:last_entry] }
    end
    @chart_max = @chart_rows.map { |r| r[:work].to_i + r[:break_secs].to_i }.max || 0
  end

  def show
    @user = User.find(params[:user_id])
    tz = @user.time_zone || Time.zone
    @view_mode = %w[day week month].include?(params[:view_mode]) ? params[:view_mode] : 'month'
    @focus_date = parse_focus_param || Date.current
    @month = parse_month_param || @focus_date.beginning_of_month
    range_from, range_to = case @view_mode
                            when 'day'
                              [@focus_date, @focus_date]
                            when 'week'
                              [@focus_date.beginning_of_week, @focus_date.end_of_week]
                            else
                              [@month, @month.end_of_month]
                            end
    @range_from = range_from
    @range_to   = range_to
    @entries = HrWorkEntry.for_user(@user)
                          .in_range(range_from.in_time_zone(tz).beginning_of_day,
                                    range_to.in_time_zone(tz).end_of_day)
                          .order(:started_at).to_a
    overlay = HrAbsence.for_user(@user).active.overlapping(@month, @month.end_of_month).to_a
    @absences_by_day = HrAbsence.build_by_day(overlay, @month, @month.end_of_month)
    @absences = HrAbsence.for_user(@user).order(starts_on: :desc).limit(50).to_a
    @summary = compute_summary(@user)
    HrEmploymentType.seed_legal_defaults! if HrEmploymentType.count.zero?
    @user_setting = HrUserSetting.for(@user)
    @employment_types = HrEmploymentType.active.ordered.to_a
    @monthly_plans = HrMonthlyPlan.for_user(@user).order(year: :desc, month: :desc).limit(36).to_a
    @monthly_plan_current = @monthly_plans.find { |p| p.year == @month.year && p.month == @month.month }
    @lecture_periods = HrLecturePeriod.for_user(@user).ordered.to_a
    @holidays_by_day = compute_user_holidays(@user, @month, @month.end_of_month)
    respond_to do |format|
      format.html
      format.csv do
        send_data HrWorkEntry.to_csv(@user, @entries),
                  filename: "hr_timeclock_#{@user.login}_#{@month.strftime('%Y-%m')}.csv",
                  type: 'text/csv; charset=utf-8'
      end
    end
  end

  def day
    @date = Date.parse(params[:date])
    range_from = @date.beginning_of_day
    range_to   = @date.end_of_day
    @entries  = HrWorkEntry.in_range(range_from, range_to).includes(:user, :hr_break_entries).order(:started_at).to_a
    @entry_rows = aggregate_entries_per_user(@entries)
    @absences = HrAbsence.where('starts_on <= ? AND ends_on >= ?', @date, @date).includes(:user, :approver).to_a
    @ticket_coverage = build_ticket_coverage(@date, @entries)
  rescue ArgumentError
    redirect_to hr_admin_path
  end

  private

  # Combine multiple work entries from the same user on the same day into a
  # single row: first start, last end, summed breaks and net work. State
  # collapses to the "most open" status across the entries so an in-progress
  # shift isn't hidden behind earlier completed segments.
  def aggregate_entries_per_user(entries)
    entries.group_by(&:user_id).map do |_uid, list|
      list = list.sort_by(&:started_at)
      has_running = list.any? { |e| e.state == HrWorkEntry::STATE_RUNNING }
      has_paused  = list.any? { |e| e.state == HrWorkEntry::STATE_PAUSED }
      has_open    = list.any? { |e| e.ended_at.nil? }
      state = if has_running then HrWorkEntry::STATE_RUNNING
              elsif has_paused then HrWorkEntry::STATE_PAUSED
              else HrWorkEntry::STATE_COMPLETED
              end
      {
        user: list.first.user,
        started_at: list.first.started_at,
        ended_at:   has_open ? nil : list.map(&:ended_at).compact.max,
        break_seconds: list.sum { |e| e.total_break_seconds },
        net_seconds:   list.sum { |e| e.net_seconds },
        state: state,
        entry_count: list.size
      }
    end.sort_by { |row| row[:started_at] }
  end

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
  rescue ArgumentError
    nil
  end

  def parse_focus_param
    return nil unless params[:focus_date].present?
    Date.parse(params[:focus_date])
  rescue ArgumentError
    nil
  end

  def parse_admin_focus_param
    return nil unless params[:focus].present?
    Date.parse(params[:focus].to_s)
  rescue ArgumentError
    nil
  end

  def build_ticket_coverage(date, work_entries)
    by_user = work_entries.group_by(&:user_id)
    user_ids = by_user.keys
    return {} if user_ids.empty?

    time_entries = TimeEntry.where(user_id: user_ids, spent_on: date)
                            .includes(:issue, :project).to_a

    user_ids.each_with_object({}) do |uid, h|
      entries = by_user[uid] || []
      worked_seconds = entries.sum { |e| e.net_seconds }
      logged = time_entries.select { |t| t.user_id == uid }
      logged_seconds = (logged.sum(&:hours).to_f * 3600).round
      per_issue = logged.group_by { |t| [t.issue_id, t.project_id] }.map do |(issue_id, project_id), ts|
        seconds = (ts.sum(&:hours).to_f * 3600).round
        issue   = ts.first.issue
        project = ts.first.project
        {
          issue_id:  issue_id,
          issue_subject: issue ? "##{issue.id} #{issue.subject}" : "(#{l(:label_hr_admin_issue_unset)})",
          project_name: project&.name,
          seconds: seconds,
          comments: ts.map(&:comments).compact.reject(&:blank?).uniq.first(3).join(' · ')
        }
      end
      h[uid] = {
        user: entries.first&.user,
        worked_seconds: worked_seconds,
        logged_seconds: logged_seconds,
        coverage: worked_seconds.positive? ? (logged_seconds.to_f / worked_seconds * 100).round(1) : nil,
        per_issue: per_issue.sort_by { |row| -row[:seconds] }
      }
    end
  rescue StandardError => e
    Rails.logger.warn("[hr] ticket coverage failed: #{e.message}")
    {}
  end

  # Sum the planned daily target across `users` for `date`, excluding people
  # who are out for the whole day on a full-day absence (vacation, sickness,
  # care). Weekends and regional public holidays already count as 0 in
  # effective_daily_target_minutes, so they fall out naturally.
  def planned_today_seconds(users, date)
    full_day_off_kinds = [HrAbsence::KIND_VACATION, HrAbsence::KIND_SICKNESS, HrAbsence::KIND_CARE]
    off_user_ids = HrAbsence.active
                            .where(kind: full_day_off_kinds)
                            .where(start_time: nil, end_time: nil)
                            .where('starts_on <= ? AND ends_on >= ?', date, date)
                            .distinct.pluck(:user_id).to_set
    users.sum do |user|
      next 0 if off_user_ids.include?(user.id)
      setting = HrUserSetting.for(user)
      mins = setting.effective_daily_target_minutes(on_date: date)
      mins.to_i * 60
    end
  end

  # Per-user metrics for the admin bar chart over an arbitrary date range:
  # work (net clocked time), break (paused time inside open shifts) and
  # coverage (TimeEntry hours booked to issues / projects).
  def compute_chart_metrics(user, range_from, range_to)
    tz = user.time_zone || Time.zone
    entries = HrWorkEntry.for_user(user)
                         .in_range(range_from.in_time_zone(tz).beginning_of_day,
                                   range_to.in_time_zone(tz).end_of_day).to_a
    now = Time.current
    work_secs  = entries.sum { |e| e.net_seconds(as_of: now) }
    break_secs = entries.sum { |e| e.total_break_seconds(as_of: now) }
    coverage_h = TimeEntry.where(user_id: user.id, spent_on: range_from..range_to).sum(:hours).to_f
    { work: work_secs.to_i, break_secs: break_secs.to_i, coverage: (coverage_h * 3600).round }
  rescue StandardError => e
    Rails.logger.warn("[hr] compute_chart_metrics failed for user #{user.id}: #{e.message}")
    { work: 0, break_secs: 0, coverage: 0 }
  end

  # Per-day list of holidays across the user list. Each entry has the holiday
  # name, the regions where it applies, and the affected vs. unaffected users
  # for that name on that day. Users without a configured region inherit the
  # federal (bundesweit) holiday set so they still see something on the
  # calendar.
  FEDERAL_REGION_SENTINEL = '__federal__'.freeze

  def compute_global_holidays(users, range_from, range_to)
    user_region = users.each_with_object({}) do |u, h|
      h[u.id] = HrUserSetting.for(u).effective_region_code.presence || FEDERAL_REGION_SENTINEL
    end
    regions_used = user_region.values.uniq
    return {} if regions_used.empty?

    region_year_maps = {}
    out = {}
    (range_from..range_to).each do |d|
      day_holidays = {}
      regions_used.each do |r|
        region_year_maps[r] ||= {}
        lookup_region = (r == FEDERAL_REGION_SENTINEL ? nil : r)
        map = (region_year_maps[r][d.year] ||= RedmineHumanResources::Holidays.holidays_for(d.year, region_code: lookup_region))
        name = map[d]
        next unless name
        entry = (day_holidays[name] ||= { regions: [], users: [] })
        display = (r == FEDERAL_REGION_SENTINEL ? 'DE' : r)
        entry[:regions] << display unless entry[:regions].include?(display)
      end
      next if day_holidays.empty?

      affected_ids = []
      users.each do |u|
        r = user_region[u.id]
        next unless r
        day_holidays.each do |_name, entry|
          if entry[:regions].include?(r)
            entry[:users] << u
            affected_ids << u.id
          end
        end
      end
      unaffected = users.reject { |u| affected_ids.include?(u.id) }

      out[d] = day_holidays.map do |name, entry|
        { name: name, regions: entry[:regions], affected: entry[:users].uniq, unaffected: unaffected }
      end
    end
    out
  rescue StandardError => e
    Rails.logger.warn("[hr] global holiday lookup failed: #{e.message}") if defined?(Rails)
    {}
  end

  # Holiday map for a single user. Falls back to federal holidays if no
  # region is configured (better than showing an empty calendar header).
  def compute_user_holidays(user, range_from, range_to)
    region = HrUserSetting.for(user).effective_region_code.presence
    year_maps = {}
    out = {}
    (range_from..range_to).each do |d|
      map = (year_maps[d.year] ||= RedmineHumanResources::Holidays.holidays_for(d.year, region_code: region))
      name = map[d]
      out[d] = [{ name: name, regions: region ? [region] : ['DE'] }] if name
    end
    out
  rescue StandardError => e
    Rails.logger.warn("[hr] admin user holiday lookup failed: #{e.message}") if defined?(Rails)
    {}
  end

  def compute_summary(user)
    tz = user.time_zone || Time.zone
    today      = Time.use_zone(tz) { Time.zone.today }
    week_from  = today.beginning_of_week
    month_from = today.beginning_of_month
    entries_today = HrWorkEntry.for_user(user).on_day(tz, today).to_a
    entries_week  = HrWorkEntry.for_user(user)
                               .in_range(week_from.in_time_zone(tz).beginning_of_day,
                                         today.in_time_zone(tz).end_of_day).to_a
    entries_month = HrWorkEntry.for_user(user)
                               .in_range(month_from.in_time_zone(tz).beginning_of_day,
                                         today.in_time_zone(tz).end_of_day).to_a
    last = HrWorkEntry.for_user(user).order(started_at: :desc).first
    {
      today: entries_today.sum { |e| e.net_seconds },
      week:  entries_week.sum  { |e| e.net_seconds },
      month: entries_month.sum { |e| e.net_seconds },
      last_entry: last
    }
  end
end
