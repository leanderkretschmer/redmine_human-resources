class HmAdminEmploymentTypesController < ApplicationController
  before_action :require_admin
  before_action :load_type, only: [:edit, :update, :destroy]

  helper :hm_timeclock

  def index
    HmEmploymentType.seed_legal_defaults! if HmEmploymentType.count.zero?
    @types = HmEmploymentType.ordered.to_a
  end

  def new
    @type = HmEmploymentType.new(yearly_vacation_days: 20)
  end

  def create
    @type = HmEmploymentType.new(type_params)
    if @type.save
      flash[:notice] = l(:notice_hm_employment_type_saved)
      redirect_to hm_admin_employment_types_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @type.update(type_params)
      flash[:notice] = l(:notice_hm_employment_type_saved)
      redirect_to hm_admin_employment_types_path
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @type.update(archived: true)
    flash[:notice] = l(:notice_hm_employment_type_archived)
    redirect_to hm_admin_employment_types_path
  end

  def seed
    HmEmploymentType.seed_legal_defaults!
    flash[:notice] = l(:notice_hm_employment_type_seeded)
    redirect_to hm_admin_employment_types_path
  end

  private

  def load_type
    @type = HmEmploymentType.find(params[:id])
  end

  def type_params
    raw = params.require(:hm_employment_type).permit(
      :name, :slug, :description,
      :weekly_target_hours, :daily_target_hours, :max_break_hours,
      :yearly_vacation_days, :weekly_school_days,
      :allows_monthly_plan, :position_order, :archived
    ).to_h

    { weekly_target_hours: :weekly_target_minutes,
      daily_target_hours:  :daily_target_minutes,
      max_break_hours:     :max_break_minutes }.each do |hour_key, min_key|
      v = raw.delete(hour_key.to_s)
      next if v.nil?
      raw[min_key.to_s] = v.to_s.strip.empty? ? nil : (v.to_f * 60).round
    end
    raw
  end
end
