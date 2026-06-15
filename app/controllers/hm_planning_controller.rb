class HmPlanningController < ApplicationController
  before_action :require_login

  helper :hm_timeclock

  def show
    @user_setting = HmUserSetting.for(User.current)
    unless @user_setting.planning_eligible?
      flash[:notice] = l(:notice_hm_planning_not_eligible)
      return redirect_to hr_timeclock_path
    end

    @kinds = @user_setting.planning_kinds
    @month = parse_month_param || Date.current.beginning_of_month
    range_from = @month
    range_to   = @month.end_of_month

    @new_absence = HmAbsence.new(kind: @kinds.first,
                                 starts_on: Date.current,
                                 ends_on: Date.current,
                                 user_id: User.current.id)

    @absences = HmAbsence.for_user(User.current).blocking
                         .order(starts_on: :desc).limit(100).to_a
    overlay = HmAbsence.for_user(User.current).active.overlapping(range_from, range_to).to_a
    @absences_by_day = HmAbsence.build_by_day(overlay, range_from, range_to)
    @lecture_periods = HmLecturePeriod.for_user(User.current)
                                      .where('starts_on <= ? AND ends_on >= ?', range_to, range_from)
                                      .to_a
    @monthly_plan    = HmMonthlyPlan.for_user(User.current).for_period(@month.year, @month.month).first
    @holidays_by_day = compute_holidays(User.current, range_from, range_to)
  end

  private

  def compute_holidays(user, range_from, range_to)
    region = HmUserSetting.for(user).effective_region_code
    return {} if region.blank?
    year_maps = {}
    out = {}
    (range_from..range_to).each do |d|
      map = (year_maps[d.year] ||= RedmineHumanResources::Holidays.holidays_for(d.year, region_code: region))
      name = map[d]
      out[d] = [{ name: name, regions: [region] }] if name
    end
    out
  rescue StandardError
    {}
  end

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
  rescue ArgumentError
    nil
  end
end
