class HmAdminController < ApplicationController
  before_action :require_admin

  helper :hm_timeclock

  def index
    @month = parse_month_param || Date.current.beginning_of_month

    base_user_ids = (HmWorkEntry.distinct.pluck(:user_id) + HmAbsence.distinct.pluck(:user_id)).uniq
    relation = User.where(id: base_user_ids)

    @filter_name = params[:filter_name].to_s.strip
    if @filter_name.present?
      n = "%#{@filter_name.downcase}%"
      relation = relation.where('LOWER(firstname) LIKE :n OR LOWER(lastname) LIKE :n OR LOWER(login) LIKE :n', n: n)
    end
    all_users = relation.sorted.to_a
    @summaries = all_users.each_with_object({}) { |u, h| h[u.id] = compute_summary(u) }
    all_users.sort_by! { |u| -(@summaries[u.id][:month].to_i) }

    range_from = @month
    range_to   = @month.end_of_month
    overlay = HmAbsence.active.overlapping(range_from, range_to).includes(:user).to_a
    @absences_by_day = HmAbsence.build_by_day(overlay, range_from, range_to)
    @pending_absences = HmAbsence.pending.includes(:user, :approver).order(:starts_on).limit(100).to_a

    # ── Dashboard KPIs (across the full filtered set, all pages) ──
    today = Date.current
    absent_today = HmAbsence.active.where('starts_on <= ? AND ends_on >= ?', today, today).distinct.pluck(:user_id)
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
    @entries = HmWorkEntry.for_user(@user)
                          .in_range(range_from.in_time_zone(tz).beginning_of_day,
                                    range_to.in_time_zone(tz).end_of_day)
                          .order(:started_at).to_a
    overlay = HmAbsence.for_user(@user).active.overlapping(@month, @month.end_of_month).to_a
    @absences_by_day = HmAbsence.build_by_day(overlay, @month, @month.end_of_month)
    @absences = HmAbsence.for_user(@user).order(starts_on: :desc).limit(50).to_a
    @summary = compute_summary(@user)
    HmEmploymentType.seed_legal_defaults! if HmEmploymentType.count.zero?
    @user_setting = HmUserSetting.for(@user)
    @employment_types = HmEmploymentType.active.ordered.to_a
    @monthly_plans = HmMonthlyPlan.for_user(@user).order(year: :desc, month: :desc).limit(36).to_a
    @lecture_periods = HmLecturePeriod.for_user(@user).ordered.to_a
    respond_to do |format|
      format.html
      format.csv do
        send_data HmWorkEntry.to_csv(@user, @entries),
                  filename: "hm_timeclock_#{@user.login}_#{@month.strftime('%Y-%m')}.csv",
                  type: 'text/csv; charset=utf-8'
      end
    end
  end

  def day
    @date = Date.parse(params[:date])
    range_from = @date.beginning_of_day
    range_to   = @date.end_of_day
    @entries  = HmWorkEntry.in_range(range_from, range_to).includes(:user, :hm_break_entries).order(:started_at).to_a
    @entry_rows = aggregate_entries_per_user(@entries)
    @absences = HmAbsence.where('starts_on <= ? AND ends_on >= ?', @date, @date).includes(:user, :approver).to_a
    @ticket_coverage = build_ticket_coverage(@date, @entries)
  rescue ArgumentError
    redirect_to hm_admin_path
  end

  private

  # Combine multiple work entries from the same user on the same day into a
  # single row: first start, last end, summed breaks and net work. State
  # collapses to the "most open" status across the entries so an in-progress
  # shift isn't hidden behind earlier completed segments.
  def aggregate_entries_per_user(entries)
    entries.group_by(&:user_id).map do |_uid, list|
      list = list.sort_by(&:started_at)
      has_running = list.any? { |e| e.state == HmWorkEntry::STATE_RUNNING }
      has_paused  = list.any? { |e| e.state == HmWorkEntry::STATE_PAUSED }
      has_open    = list.any? { |e| e.ended_at.nil? }
      state = if has_running then HmWorkEntry::STATE_RUNNING
              elsif has_paused then HmWorkEntry::STATE_PAUSED
              else HmWorkEntry::STATE_COMPLETED
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
          issue_subject: issue ? "##{issue.id} #{issue.subject}" : "(#{l(:label_hm_admin_issue_unset)})",
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
    full_day_off_kinds = [HmAbsence::KIND_VACATION, HmAbsence::KIND_SICKNESS, HmAbsence::KIND_CARE]
    off_user_ids = HmAbsence.active
                            .where(kind: full_day_off_kinds)
                            .where(start_time: nil, end_time: nil)
                            .where('starts_on <= ? AND ends_on >= ?', date, date)
                            .distinct.pluck(:user_id).to_set
    users.sum do |user|
      next 0 if off_user_ids.include?(user.id)
      setting = HmUserSetting.for(user)
      mins = setting.effective_daily_target_minutes(on_date: date)
      mins.to_i * 60
    end
  end

  # Per-user metrics for the admin bar chart over an arbitrary date range:
  # work (net clocked time), break (paused time inside open shifts) and
  # coverage (TimeEntry hours booked to issues / projects).
  def compute_chart_metrics(user, range_from, range_to)
    tz = user.time_zone || Time.zone
    entries = HmWorkEntry.for_user(user)
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

  def compute_summary(user)
    tz = user.time_zone || Time.zone
    today      = Time.use_zone(tz) { Time.zone.today }
    week_from  = today.beginning_of_week
    month_from = today.beginning_of_month
    entries_today = HmWorkEntry.for_user(user).on_day(tz, today).to_a
    entries_week  = HmWorkEntry.for_user(user)
                               .in_range(week_from.in_time_zone(tz).beginning_of_day,
                                         today.in_time_zone(tz).end_of_day).to_a
    entries_month = HmWorkEntry.for_user(user)
                               .in_range(month_from.in_time_zone(tz).beginning_of_day,
                                         today.in_time_zone(tz).end_of_day).to_a
    last = HmWorkEntry.for_user(user).order(started_at: :desc).first
    {
      today: entries_today.sum { |e| e.net_seconds },
      week:  entries_week.sum  { |e| e.net_seconds },
      month: entries_month.sum { |e| e.net_seconds },
      last_entry: last
    }
  end
end
