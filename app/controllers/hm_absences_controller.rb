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

    starts_on = parse_date(permitted[:starts_on])
    ends_on   = parse_date(permitted[:ends_on]) || starts_on

    hard_gate = HmAbsence.validate_kind_window(permitted[:kind], starts_on, ends_on)
    if hard_gate
      flash[:error] = window_error_message(permitted[:kind], hard_gate)
      return redirect_back(fallback_location: hm_timeclock_path)
    end
    unless User.current.admin?
      user_gate = HmAbsence.validate_user_window(permitted[:kind], starts_on, ends_on)
      if user_gate
        flash[:error] = window_error_message(permitted[:kind], user_gate)
        return redirect_back(fallback_location: hm_timeclock_path)
      end
    end

    status = if HmAbsence::AUTO_APPROVED_KINDS.include?(permitted[:kind])
               HmAbsence::STATUS_APPROVED
             else
               HmAbsence::STATUS_REQUESTED
             end

    @absence = HmAbsence.new(permitted.merge(
      user_id: User.current.id,
      status: status,
      approved_by_id: status == HmAbsence::STATUS_APPROVED ? User.current.id : nil,
      approved_at:    status == HmAbsence::STATUS_APPROVED ? Time.current      : nil
    ))
    if @absence.save
      @absence.log_audit!(User.current, HmAbsenceAudit::ACTION_CREATED, to_status: @absence.status)
      HmAbsenceMailer.deliver_absence_requested(@absence) if @absence.vacation?
      flash[:notice] = if @absence.vacation?
                         l(:notice_hm_absence_requested)
                       elsif @absence.sickness?
                         l(:notice_hm_sickness_logged)
                       else
                         l(:notice_hm_offsite_logged)
                       end
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

    if @absence.sickness? || @absence.offsite?
      starts_on = parse_date(attrs[:starts_on])
      ends_on   = parse_date(attrs[:ends_on]) || starts_on
      gate = HmAbsence.validate_kind_window(@absence.kind, starts_on, ends_on)
      gate ||= HmAbsence.validate_user_window(@absence.kind, starts_on, ends_on) unless User.current.admin?
      if gate
        msg = window_error_message(@absence.kind, gate)
        return respond_with_failure(msg)
      end
    end

    attrs[:status] = HmAbsence::STATUS_REQUESTED if !User.current.admin? && @absence.vacation?

    prior_status = @absence.status
    if @absence.update(attrs)
      @absence.log_audit!(User.current, HmAbsenceAudit::ACTION_UPDATED,
                          from_status: prior_status, to_status: @absence.status)
      if User.current.admin? && @absence.user_id != User.current.id
        HmAbsenceMailer.deliver_absence_edited(@absence, User.current)
      end
      respond_to do |format|
        format.html do
          flash[:notice] = l(:notice_hm_absence_updated)
          redirect_back(fallback_location: redirect_target)
        end
        format.json { render json: { ok: true } }
      end
    else
      respond_with_failure(@absence.errors.full_messages.join(', '))
    end
  end

  def destroy
    if can_delete?
      @absence.destroy
      flash[:notice] = l(:notice_hm_absence_deleted)
    else
      flash[:error] = l(:notice_hm_absence_forbidden)
    end
    redirect_back(fallback_location: redirect_target)
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
    return true if User.current.admin?
    return false unless owner?
    @absence.vacation? ? @absence.requested? : true
  end

  def can_delete?
    can_edit?
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

  def respond_with_failure(message)
    respond_to do |format|
      format.html do
        flash[:error] = message
        redirect_back(fallback_location: redirect_target)
      end
      format.json { render json: { error: message }, status: :unprocessable_entity }
    end
  end

  def parse_date(value)
    return value if value.is_a?(Date)
    return nil if value.blank?
    Date.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def window_error_message(kind, code)
    case code
    when :future_not_allowed
      kind == HmAbsence::KIND_SICKNESS ? l(:notice_hm_sickness_no_future) : l(:notice_hm_offsite_no_future)
    when :future_start_not_allowed
      l(:notice_hm_sickness_no_future_start)
    when :backdate_exceeded
      l(:notice_hm_sickness_backdate_limit, days: HmAbsence::USER_BACKDATE_LIMIT_DAYS)
    else
      l(:notice_hm_absence_forbidden)
    end
  end
end
