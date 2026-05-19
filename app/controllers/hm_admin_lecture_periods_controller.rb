class HmAdminLecturePeriodsController < ApplicationController
  before_action :require_admin
  before_action :load_user

  def create
    period = HmLecturePeriod.new(period_params.merge(user_id: @user.id))
    if period.save
      flash[:notice] = l(:notice_hm_lecture_period_saved)
    else
      flash[:error] = period.errors.full_messages.join(', ')
    end
    redirect_to hm_admin_user_path(user_id: @user.id)
  end

  def update
    period = HmLecturePeriod.for_user(@user).find(params[:id])
    if period.update(period_params)
      flash[:notice] = l(:notice_hm_lecture_period_saved)
    else
      flash[:error] = period.errors.full_messages.join(', ')
    end
    redirect_to hm_admin_user_path(user_id: @user.id)
  end

  def destroy
    period = HmLecturePeriod.for_user(@user).find(params[:id])
    period.destroy
    flash[:notice] = l(:notice_hm_lecture_period_deleted)
    redirect_to hm_admin_user_path(user_id: @user.id)
  end

  private

  def load_user
    @user = User.find(params[:user_id])
  end

  def period_params
    raw = params.require(:hm_lecture_period).permit(
      :kind, :starts_on, :ends_on,
      :weekly_target_hours, :daily_target_hours,
      :label, :notes
    ).to_h

    { weekly_target_hours: :weekly_target_minutes,
      daily_target_hours:  :daily_target_minutes }.each do |hk, mk|
      v = raw.delete(hk.to_s)
      next if v.nil?
      raw[mk.to_s] = v.to_s.strip.empty? ? nil : (v.to_f * 60).round
    end
    raw
  end
end
