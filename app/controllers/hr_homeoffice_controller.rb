class HrHomeofficeController < ApplicationController
  before_action :require_login

  helper :hr_timeclock

  def show
    load_state
    @new_absence = HrAbsence.new(kind: HrAbsence::KIND_HOMEOFFICE,
                                 starts_on: Date.current,
                                 ends_on: Date.current,
                                 user_id: User.current.id)
  end

  def create
    @new_absence = HrAbsence.new(absence_params.merge(
      kind: HrAbsence::KIND_HOMEOFFICE,
      user_id: User.current.id,
      status: HrAbsence::STATUS_REQUESTED
    ))
    if @new_absence.save
      @new_absence.log_audit!(User.current, HrAbsenceAudit::ACTION_CREATED, to_status: @new_absence.status)
      HrAbsenceMailer.deliver_absence_requested(@new_absence)
      flash[:notice] = l(:notice_hr_absence_requested)
      redirect_to hr_homeoffice_path
    else
      load_state
      render :show, status: :unprocessable_entity
    end
  end

  private

  def load_state
    @kind = HrAbsence::KIND_HOMEOFFICE
    @month = parse_month_param || Date.current.beginning_of_month
    @absences = HrAbsence.for_user(User.current).homeoffice.order(starts_on: :desc).limit(50).to_a
    range_from = @month
    range_to   = @month.end_of_month
    overlay = HrAbsence.for_user(User.current).active.overlapping(range_from, range_to).to_a
    @absences_by_day = HrAbsence.build_by_day(overlay, range_from, range_to)
    @remaining = HrAbsence.homeoffice_remaining(User.current)
  end

  def absence_params
    params.require(:hr_absence).permit(:starts_on, :ends_on, :reason,
                                       :first_day_half, :last_day_half,
                                       :recurrence, :recurrence_until)
  end

  def parse_month_param
    return nil unless params[:month].present?
    Date.parse("#{params[:month]}-01")
  rescue ArgumentError
    nil
  end
end
