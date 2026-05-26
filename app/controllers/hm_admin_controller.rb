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
      users:        all_users.size,
      worked_month: all_users.sum { |u| @summaries[u.id][:month].to_i },
      worked_today: all_users.sum { |u| @summaries[u.id][:today].to_i },
      pending:      @pending_absences.size,
      absent_today: (absent_today & all_users.map(&:id)).size
    }
    @chart_max = all_users.map { |u| @summaries[u.id][:month].to_i }.max || 0

    # ── Pagination of the employee list (10/page) ──
    per_page = 10
    @user_count = all_users.size
    @paginator = Redmine::Pagination::Paginator.new(@user_count, per_page, params[:page])
    @chart_rows = (all_users[@paginator.offset, @paginator.per_page] || [])
                   .map { |u| { user: u, seconds: @summaries[u.id][:month].to_i, last_entry: @summaries[u.id][:last_entry] } }
  end

  def show
    @user = User.find(params[:user_id])
    tz = @user.time_zone || Time.zone
    @month = parse_month_param || Date.current.beginning_of_month
    @entries = HmWorkEntry.for_user(@user)
                          .in_range(@month.in_time_zone(tz).beginning_of_day,
                                    @month.end_of_month.in_time_zone(tz).end_of_day)
                          .order(:started_at).to_a
    range_from = @month
    range_to   = @month.end_of_month
    overlay = HmAbsence.for_user(@user).active.overlapping(range_from, range_to).to_a
    @absences_by_day = HmAbsence.build_by_day(overlay, range_from, range_to)
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
    @entries  = HmWorkEntry.in_range(range_from, range_to).includes(:user).order(:started_at).to_a
    @absences = HmAbsence.where('starts_on <= ? AND ends_on >= ?', @date, @date).includes(:user, :approver).to_a
    @ticket_coverage = build_ticket_coverage(@date, @entries)
  rescue ArgumentError
    redirect_to hm_admin_path
  end

  private

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
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
    Rails.logger.warn("[hm_cratchmere] ticket coverage failed: #{e.message}")
    {}
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
