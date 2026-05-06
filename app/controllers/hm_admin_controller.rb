class HmAdminController < ApplicationController
  before_action :require_admin

  helper :hm_timeclock

  def index
    user_ids = HmWorkEntry.distinct.pluck(:user_id)
    @users = User.where(id: user_ids).sorted.to_a
    @summaries = @users.each_with_object({}) do |u, h|
      h[u.id] = compute_summary(u)
    end
    @users.sort_by! { |u| -(@summaries[u.id][:month].to_i) }
  end

  def show
    @user = User.find(params[:user_id])
    tz = @user.time_zone || Time.zone
    @month = parse_month_param || Date.current.beginning_of_month
    @entries = HmWorkEntry.for_user(@user)
                          .in_range(@month.in_time_zone(tz).beginning_of_day,
                                    @month.end_of_month.in_time_zone(tz).end_of_day)
                          .order(:started_at).to_a
    @summary = compute_summary(@user)
    respond_to do |format|
      format.html
      format.csv do
        send_data HmWorkEntry.to_csv(@user, @entries),
                  filename: "hm_timeclock_#{@user.login}_#{@month.strftime('%Y-%m')}.csv",
                  type: 'text/csv; charset=utf-8'
      end
    end
  end

  private

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
  rescue ArgumentError
    nil
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
