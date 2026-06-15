class HrPlanningController < ApplicationController
  before_action :require_login

  helper :hr_timeclock

  def show
    @user_setting = HrUserSetting.for(User.current)
    unless @user_setting.planning_eligible?
      flash[:notice] = l(:notice_hr_planning_not_eligible)
      return redirect_to hr_timeclock_path
    end

    @kinds = @user_setting.planning_kinds
    @month = parse_month_param || Date.current.beginning_of_month
    range_from = @month
    range_to   = @month.end_of_month

    @new_absence = HrAbsence.new(kind: @kinds.first,
                                 starts_on: Date.current,
                                 ends_on: Date.current,
                                 user_id: User.current.id)

    @absences = HrAbsence.for_user(User.current).blocking
                         .order(starts_on: :desc).limit(100).to_a
    overlay = HrAbsence.for_user(User.current).active.overlapping(range_from, range_to).to_a
    @absences_by_day = HrAbsence.build_by_day(overlay, range_from, range_to)
    @lecture_periods = HrLecturePeriod.for_user(User.current)
                                      .where('starts_on <= ? AND ends_on >= ?', range_to, range_from)
                                      .to_a
    @monthly_plan    = HrMonthlyPlan.for_user(User.current).for_period(@month.year, @month.month).first
    @holidays_by_day = compute_holidays(User.current, range_from, range_to)
  end

  private

  def compute_holidays(user, range_from, range_to)
    region = HrUserSetting.for(user).effective_region_code.presence
    year_maps = {}
    out = {}
    (range_from..range_to).each do |d|
      map = (year_maps[d.year] ||= RedmineHumanResources::Holidays.holidays_for(d.year, region_code: region))
      name = map[d]
      out[d] = [{ name: name, regions: region ? [region] : ['DE'] }] if name
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
