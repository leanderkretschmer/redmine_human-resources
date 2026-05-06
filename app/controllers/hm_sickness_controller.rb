class HmSicknessController < ApplicationController
  before_action :require_login

  helper :hm_timeclock

  def show
    load_state
    @new_absence = HmAbsence.new(kind: HmAbsence::KIND_SICKNESS,
                                 starts_on: Date.current,
                                 ends_on: Date.current,
                                 user_id: User.current.id)
  end

  def create
    @new_absence = HmAbsence.new(absence_params.merge(
      kind: HmAbsence::KIND_SICKNESS,
      user_id: User.current.id,
      status: HmAbsence::STATUS_REQUESTED
    ))
    if @new_absence.save
      @new_absence.log_audit!(User.current, HmAbsenceAudit::ACTION_CREATED, to_status: @new_absence.status)
      flash[:notice] = l(:notice_hm_absence_requested)
      redirect_to hm_sickness_path
    else
      load_state
      render :show, status: :unprocessable_entity
    end
  end

  private

  def load_state
    @kind = HmAbsence::KIND_SICKNESS
    @month = parse_month_param || Date.current.beginning_of_month
    @absences = HmAbsence.for_user(User.current).sickness.order(starts_on: :desc).limit(50).to_a
    range_from = @month
    range_to   = @month.end_of_month
    overlay = HmAbsence.for_user(User.current).active.overlapping(range_from, range_to).to_a
    @absences_by_day = HmAbsence.build_by_day(overlay, range_from, range_to)
  end

  def absence_params
    params.require(:hm_absence).permit(:starts_on, :ends_on, :reason)
  end

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
  rescue ArgumentError
    nil
  end
end
