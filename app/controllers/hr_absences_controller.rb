class HrAbsencesController < ApplicationController
  before_action :require_login
  before_action :find_absence, except: [:create]

  helper :hr_timeclock

  def create
    permitted = params.require(:hr_absence).permit(:kind, :starts_on, :ends_on, :reason,
                                                   :recurrence, :recurrence_until,
                                                   :first_day_half, :last_day_half,
                                                   :start_time, :end_time, :user_id)
    unless HrAbsence::KINDS.include?(permitted[:kind])
      return respond_create_failure(l(:notice_hr_absence_forbidden))
    end

    # Admins may target a specific user (or all active users) when creating
    # absences from the calendar; non-admins always book against themselves.
    target_user_ids = resolve_target_user_ids(permitted[:user_id])
    if target_user_ids.empty?
      return respond_create_failure(l(:notice_hr_absence_forbidden))
    end
    admin_acting = User.current.admin?

    starts_on = parse_date(permitted[:starts_on])
    ends_on   = parse_date(permitted[:ends_on]) || starts_on

    hard_gate = HrAbsence.validate_kind_window(permitted[:kind], starts_on, ends_on)
    if hard_gate
      return respond_create_failure(window_error_message(permitted[:kind], hard_gate))
    end
    unless admin_acting
      user_gate = HrAbsence.validate_user_window(permitted[:kind], starts_on, ends_on)
      if user_gate
        return respond_create_failure(window_error_message(permitted[:kind], user_gate))
      end
    end

    recurrence_capable = HrAbsence::RECURRENCE_CAPABLE_KINDS.include?(permitted[:kind])
    recurrence_kind  = permitted[:recurrence].to_s.presence
    recurrence_until = parse_date(permitted[:recurrence_until])
    if recurrence_capable &&
       recurrence_kind &&
       recurrence_kind != HrAbsence::RECURRENCE_NONE &&
       recurrence_until.blank?
      return respond_create_failure(l(:notice_hr_recurrence_until_required))
    end

    pairs = if recurrence_capable
              HrAbsence.expand_recurrence(starts_on, ends_on, recurrence_kind, recurrence_until)
            else
              [[starts_on, ends_on]]
            end

    # When an admin books an absence from the calendar (whether for one user or
    # the entire active roster), the entry is approved on the spot — there is
    # nobody above the admin to wait on.
    approve_admin = admin_acting
    status = if approve_admin || HrAbsence::AUTO_APPROVED_KINDS.include?(permitted[:kind])
               HrAbsence::STATUS_APPROVED
             else
               HrAbsence::STATUS_REQUESTED
             end

    # Half days only apply to vacation (single contiguous booking, no recurrence).
    half_eligible = permitted[:kind] == HrAbsence::KIND_VACATION
    first_half = half_eligible && truthy_param(permitted[:first_day_half])
    last_half  = half_eligible && truthy_param(permitted[:last_day_half])

    created = []
    HrAbsence.transaction do
      target_user_ids.each do |uid|
        if HrAbsence::EXCLUSIVE_KINDS.include?(permitted[:kind]) &&
           HrAbsence.overlapping_for(uid, permitted[:kind], starts_on, ends_on).exists?
          next
        end
        pairs.each do |s, e|
          absence = HrAbsence.new(
            kind: permitted[:kind],
            reason: permitted[:reason],
            starts_on: s,
            ends_on:   e,
            first_day_half: first_half,
            last_day_half:  last_half,
            start_time: normalize_hhmm(permitted[:start_time]),
            end_time:   normalize_hhmm(permitted[:end_time]),
            user_id: uid,
            status: status,
            approved_by_id: status == HrAbsence::STATUS_APPROVED ? User.current.id : nil,
            approved_at:    status == HrAbsence::STATUS_APPROVED ? Time.current      : nil
          )
          absence.save!
          absence.log_audit!(User.current, HrAbsenceAudit::ACTION_CREATED, to_status: absence.status)
          created << absence
        end
      end
    end

    @absence = created.first
    notice = nil
    if @absence
      HrAbsenceMailer.deliver_absence_requested(@absence) if @absence.vacation? && !admin_acting
      notice = if created.size > 1
                 l(:notice_hr_recurrence_created, count: created.size)
               elsif @absence.vacation?
                 l(:notice_hr_absence_requested)
               elsif @absence.sickness?
                 l(:notice_hr_sickness_logged)
               else
                 l(:notice_hr_offsite_logged)
               end
    end
    respond_create_success(notice)
  rescue ActiveRecord::RecordInvalid => e
    respond_create_failure(e.record&.errors&.full_messages&.join(', ') || e.message)
  end

  def edit
    return unless authorize_edit!
  end

  def update
    return unless authorize_edit!
    attrs = absence_params

    new_starts_on = parse_date(attrs[:starts_on]) || @absence.starts_on
    new_ends_on   = parse_date(attrs[:ends_on])   || @absence.ends_on

    if @absence.sickness? || @absence.offsite?
      gate = HrAbsence.validate_kind_window(@absence.kind, new_starts_on, new_ends_on)
      gate ||= HrAbsence.validate_user_window(@absence.kind, new_starts_on, new_ends_on) unless User.current.admin?
      if gate
        return respond_with_failure(window_error_message(@absence.kind, gate))
      end
    end

    if HrAbsence::EXCLUSIVE_KINDS.include?(@absence.kind) &&
       HrAbsence.overlapping_for(@absence.user_id, @absence.kind, new_starts_on, new_ends_on, exclude_id: @absence.id).exists?
      return respond_with_failure(l(:notice_hr_absence_overlap, kind: HrAbsence.kind_label(@absence.kind)))
    end

    attrs[:status] = HrAbsence::STATUS_REQUESTED if !User.current.admin? && @absence.vacation?

    prior_status = @absence.status
    if @absence.update(attrs)
      @absence.log_audit!(User.current, HrAbsenceAudit::ACTION_UPDATED,
                          from_status: prior_status, to_status: @absence.status)
      if User.current.admin? && @absence.user_id != User.current.id
        HrAbsenceMailer.deliver_absence_edited(@absence, User.current)
      end
      respond_to do |format|
        format.html do
          flash[:notice] = l(:notice_hr_absence_updated)
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
      flash[:notice] = l(:notice_hr_absence_deleted)
    else
      flash[:error] = l(:notice_hr_absence_forbidden)
    end
    redirect_back(fallback_location: redirect_target)
  end

  def approve
    return forbidden! unless User.current.admin?
    @absence.approve_by!(User.current)
    HrAbsenceMailer.deliver_absence_decided(@absence)
    flash[:notice] = l(:notice_hr_absence_approved)
    redirect_back(fallback_location: hr_admin_path)
  end

  def reject
    return forbidden! unless User.current.admin?
    @absence.reject_by!(User.current)
    HrAbsenceMailer.deliver_absence_decided(@absence)
    flash[:notice] = l(:notice_hr_absence_rejected)
    redirect_back(fallback_location: hr_admin_path)
  end

  private

  # Translate the modal's user_id selection into the list of users we'll book
  # against. Non-admins are pinned to themselves; admins target a specific
  # user (numeric id) or the HR roster (explicit "all" sentinel — same set
  # the admin dashboard's chart rows are drawn from: anyone with a work
  # entry or absence on record). Anything else — including a missing field,
  # which is the case for the day-detail timeline popover that has no user
  # picker — falls back to the current actor so admins booking their own
  # time aren't accidentally spamming every employee.
  def resolve_target_user_ids(raw_value)
    return [User.current.id] unless User.current.admin?
    s = raw_value.to_s.strip
    return [User.current.id] if s.empty?
    return hr_user_ids if s == 'all'
    id = s.to_i
    return [] unless id.positive?
    User.where(id: id).pluck(:id)
  rescue StandardError
    []
  end

  # The set of HR users — same definition as HrAdminController#index uses to
  # populate the bar-graph rows: every active, non-anonymous user that has
  # at least one HrWorkEntry or HrAbsence on record.
  def hr_user_ids
    ids = (HrWorkEntry.distinct.pluck(:user_id) + HrAbsence.distinct.pluck(:user_id)).uniq
    return [] if ids.empty?
    User.active.where(id: ids).where.not(type: 'AnonymousUser').pluck(:id)
  end

  def find_absence
    @absence = HrAbsence.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.json { render json: { error: l(:notice_hr_absence_not_found) }, status: :not_found and return }
      format.html { redirect_back(fallback_location: hr_timeclock_path, alert: l(:notice_hr_absence_not_found)) and return }
    end
  end

  def owner?
    @absence.user_id == User.current.id
  end

  def can_edit?
    return true if User.current.admin?
    return false unless owner?
    # Vacation needs to still be pending; everything else (sickness, offsite,
    # school, blocked) the owner may always edit/remove.
    @absence.vacation? ? @absence.requested? : true
  end

  def can_delete?
    can_edit?
  end

  def authorize_edit!
    return true if can_edit?
    flash[:error] = l(:notice_hr_absence_forbidden)
    redirect_to redirect_target
    false
  end

  def absence_params
    permitted = params.require(:hr_absence).permit(:starts_on, :ends_on, :reason,
                                                   :first_day_half, :last_day_half,
                                                   :start_time, :end_time)
    # Half-day flags are only meaningful for vacation.
    unless @absence&.vacation?
      permitted.delete(:first_day_half)
      permitted.delete(:last_day_half)
    end
    if permitted.key?(:start_time)
      permitted[:start_time] = normalize_hhmm(permitted[:start_time])
    end
    if permitted.key?(:end_time)
      permitted[:end_time] = normalize_hhmm(permitted[:end_time])
    end
    permitted
  end

  def truthy_param(value)
    ['1', 1, true, 'true', 'on'].include?(value)
  end

  def normalize_hhmm(value)
    return nil if value.blank?
    s = value.to_s.strip
    return nil if s.empty?
    return s if s.match?(/\A\d{1,2}:\d{2}\z/)
    nil
  end

  def respond_create_failure(message)
    respond_to do |format|
      format.html do
        flash[:error] = message
        redirect_back(fallback_location: hr_timeclock_path)
      end
      format.json { render json: { error: message }, status: :unprocessable_entity }
    end
  end

  def respond_create_success(message)
    respond_to do |format|
      format.html do
        flash[:notice] = message if message.present?
        redirect_back(fallback_location: hr_timeclock_path)
      end
      format.json { render json: { ok: true, id: @absence&.id, message: message } }
    end
  end

  def redirect_target
    case @absence.kind
    when HrAbsence::KIND_VACATION then hr_vacation_path
    when HrAbsence::KIND_SICKNESS then hr_sickness_path
    when HrAbsence::KIND_SCHOOL, HrAbsence::KIND_BLOCK then hr_planning_path
    else hr_timeclock_path
    end
  end

  def forbidden!
    flash[:error] = l(:notice_hr_absence_forbidden)
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
      kind == HrAbsence::KIND_SICKNESS ? l(:notice_hr_sickness_no_future) : l(:notice_hr_offsite_no_future)
    when :future_start_not_allowed
      l(:notice_hr_sickness_no_future_start)
    when :backdate_exceeded
      l(:notice_hr_sickness_backdate_limit, days: HrAbsence::USER_BACKDATE_LIMIT_DAYS)
    else
      l(:notice_hr_absence_forbidden)
    end
  end
end
