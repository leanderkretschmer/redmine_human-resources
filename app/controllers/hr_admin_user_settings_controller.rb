class HrAdminUserSettingsController < ApplicationController
  before_action :require_admin

  helper :hr_timeclock

  def update
    user    = User.find(params[:user_id])
    setting = HrUserSetting.for(user)

    raw = params.require(:hr_user_setting).permit(
      :hr_employment_type_id, :region_code,
      :daily_target_hours, :weekly_target_hours, :max_break_hours,
      :yearly_vacation_days_override, :weekly_school_days_override,
      :allows_monthly_plan_override, :notify_target_reached, :notify_break_over,
      :homeoffice_days_per_year_override,
      :care_status, :care_hours_per_year_override,
      school_weekdays_override: []
    ).to_h

    { daily_target_hours: :daily_target_minutes,
      weekly_target_hours: :weekly_target_minutes,
      max_break_hours: :max_break_minutes }.each do |hour_key, min_key|
      v = raw.delete(hour_key.to_s)
      next if v.nil?
      raw[min_key.to_s] = v.to_s.strip.empty? ? nil : (v.to_f * 60).round
    end

    raw['hr_employment_type_id'] = nil if raw['hr_employment_type_id'].to_s.empty?
    raw['region_code'] = nil if raw['region_code'].to_s.strip.empty?
    raw['care_status'] = nil if raw['care_status'].to_s.strip.empty?
    %w[homeoffice_days_per_year_override care_hours_per_year_override].each do |k|
      raw[k] = nil if raw[k].to_s.strip.empty?
    end

    if raw.key?('school_weekdays_override')
      values = Array(raw['school_weekdays_override']).map(&:to_s).reject(&:blank?).uniq
      raw['school_weekdays_override'] = values.any? ? values.sort_by(&:to_i).join(',') : nil
      # Keep weekly_school_days_override consistent with the explicit list
      raw['weekly_school_days_override'] = values.any? ? values.size : nil
    end

    if setting.update(raw)
      flash[:notice] = l(:notice_hr_timeclock_settings_saved)
    else
      flash[:error] = setting.errors.full_messages.join(', ')
    end
    redirect_to hr_admin_user_path(user_id: user.id)
  end
end
