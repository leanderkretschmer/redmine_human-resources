class HmAdminUserSettingsController < ApplicationController
  before_action :require_admin

  helper :hm_timeclock

  def update
    user    = User.find(params[:user_id])
    setting = HmUserSetting.for(user)

    raw = params.require(:hm_user_setting).permit(
      :hm_employment_type_id,
      :daily_target_hours, :weekly_target_hours, :max_break_hours,
      :yearly_vacation_days_override, :weekly_school_days_override,
      :allows_monthly_plan_override, :notify_target_reached, :notify_break_over
    ).to_h

    { daily_target_hours: :daily_target_minutes,
      weekly_target_hours: :weekly_target_minutes,
      max_break_hours: :max_break_minutes }.each do |hour_key, min_key|
      v = raw.delete(hour_key.to_s)
      next if v.nil?
      raw[min_key.to_s] = v.to_s.strip.empty? ? nil : (v.to_f * 60).round
    end

    raw['hm_employment_type_id'] = nil if raw['hm_employment_type_id'].to_s.empty?

    if setting.update(raw)
      flash[:notice] = l(:notice_hm_timeclock_settings_saved)
    else
      flash[:error] = setting.errors.full_messages.join(', ')
    end
    redirect_to hm_admin_user_path(user_id: user.id)
  end
end
