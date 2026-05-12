class HmAdminMonthlyPlansController < ApplicationController
  before_action :require_admin
  before_action :load_user

  def create
    raw = plan_params
    plan = HmMonthlyPlan.find_or_initialize_by(user_id: @user.id, year: raw[:year], month: raw[:month])
    plan.assign_attributes(target_minutes: hours_to_minutes(raw[:target_hours]),
                           notes: raw[:notes],
                           created_by_id: User.current.id)
    if plan.save
      flash[:notice] = l(:notice_hm_monthly_plan_saved)
    else
      flash[:error] = plan.errors.full_messages.join(', ')
    end
    redirect_to hm_admin_user_path(user_id: @user.id)
  end

  def update
    plan = HmMonthlyPlan.where(user_id: @user.id).find(params[:id])
    raw = plan_params
    if plan.update(target_minutes: hours_to_minutes(raw[:target_hours]),
                   notes: raw[:notes])
      flash[:notice] = l(:notice_hm_monthly_plan_saved)
    else
      flash[:error] = plan.errors.full_messages.join(', ')
    end
    redirect_to hm_admin_user_path(user_id: @user.id)
  end

  def destroy
    plan = HmMonthlyPlan.where(user_id: @user.id).find(params[:id])
    plan.destroy
    flash[:notice] = l(:notice_hm_monthly_plan_removed)
    redirect_to hm_admin_user_path(user_id: @user.id)
  end

  private

  def load_user
    @user = User.find(params[:user_id])
  end

  def plan_params
    params.require(:hm_monthly_plan).permit(:year, :month, :target_hours, :notes)
  end

  def hours_to_minutes(value)
    value.to_s.strip.empty? ? 0 : (value.to_f * 60).round
  end
end
