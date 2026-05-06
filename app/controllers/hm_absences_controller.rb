class HmAbsencesController < ApplicationController
  before_action :require_login
  before_action :find_absence, except: [:create]

  helper :hm_timeclock

  def create
    permitted = params.require(:hm_absence).permit(:kind, :starts_on, :ends_on, :reason)
    unless HmAbsence::KINDS.include?(permitted[:kind])
      flash[:error] = l(:notice_hm_absence_forbidden)
      return redirect_back(fallback_location: hm_timeclock_path)
    end
    @absence = HmAbsence.new(permitted.merge(
      user_id: User.current.id,
      status: HmAbsence::STATUS_REQUESTED
    ))
    if @absence.save
      @absence.log_audit!(User.current, HmAbsenceAudit::ACTION_CREATED, to_status: @absence.status)
      HmAbsenceMailer.deliver_absence_requested(@absence)
      flash[:notice] = l(:notice_hm_absence_requested)
    else
      flash[:error] = @absence.errors.full_messages.join(', ')
    end
    redirect_back(fallback_location: hm_timeclock_path)
  end

  def edit
    return unless authorize_edit!
  end

  def update
    return unless authorize_edit!
    attrs = absence_params
    attrs[:status] = HmAbsence::STATUS_REQUESTED unless User.current.admin?
    prior_status = @absence.status
    if @absence.update(attrs)
      @absence.log_audit!(User.current, HmAbsenceAudit::ACTION_UPDATED,
                          from_status: prior_status, to_status: @absence.status)
      if User.current.admin? && @absence.user_id != User.current.id
        HmAbsenceMailer.deliver_absence_edited(@absence, User.current)
      end
      flash[:notice] = l(:notice_hm_absence_updated)
      redirect_to redirect_target
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if can_delete?
      @absence.destroy
      flash[:notice] = l(:notice_hm_absence_deleted)
    else
      flash[:error] = l(:notice_hm_absence_forbidden)
    end
    redirect_to redirect_target
  end

  def approve
    return forbidden! unless User.current.admin?
    @absence.approve_by!(User.current)
    HmAbsenceMailer.deliver_absence_decided(@absence)
    flash[:notice] = l(:notice_hm_absence_approved)
    redirect_back(fallback_location: hm_admin_path)
  end

  def reject
    return forbidden! unless User.current.admin?
    @absence.reject_by!(User.current)
    HmAbsenceMailer.deliver_absence_decided(@absence)
    flash[:notice] = l(:notice_hm_absence_rejected)
    redirect_back(fallback_location: hm_admin_path)
  end

  private

  def find_absence
    @absence = HmAbsence.find(params[:id])
  end

  def owner?
    @absence.user_id == User.current.id
  end

  def can_edit?
    User.current.admin? || (owner? && @absence.requested?)
  end

  def can_delete?
    User.current.admin? || (owner? && @absence.requested?)
  end

  def authorize_edit!
    return true if can_edit?
    flash[:error] = l(:notice_hm_absence_forbidden)
    redirect_to redirect_target
    false
  end

  def absence_params
    params.require(:hm_absence).permit(:starts_on, :ends_on, :reason)
  end

  def redirect_target
    case @absence.kind
    when HmAbsence::KIND_VACATION then hm_vacation_path
    when HmAbsence::KIND_SICKNESS then hm_sickness_path
    else hm_timeclock_path
    end
  end

  def forbidden!
    flash[:error] = l(:notice_hm_absence_forbidden)
    redirect_to redirect_target
  end
end
