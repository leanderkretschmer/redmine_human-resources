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

    # The unified entry modal can send a `per_day` hash with one time-window
    # per calendar date — in that case we create one record per entry rather
    # than a single multi-day range. Otherwise fall back to the usual single
    # pair (optionally expanded by recurrence) using the global start/end
    # time (or none, for full-day entries).
    per_day = parse_per_day_param
    pairs = if per_day.any?
              per_day
            elsif recurrence_capable
              HrAbsence.expand_recurrence(starts_on, ends_on, recurrence_kind, recurrence_until)
                       .map { |s, e| [s, e, nil, nil] }
            else
              [[starts_on, ends_on, nil, nil]]
            end

    # Fill per-pair times with the global start/end when absent, then split
    # any multi-day pair that carries a time window into one record per
    # calendar day — the model only accepts start/end time on same-day
    # entries (`time_range_consistent`).
    global_start = normalize_hhmm(permitted[:start_time])
    global_end   = normalize_hhmm(permitted[:end_time])
    pairs = pairs.map { |s, e, pst, pen| [s, e, pst.presence || global_start, pen.presence || global_end] }
    pairs = pairs.flat_map do |s, e, pst, pen|
      if s != e && (pst || pen)
        (s..e).map { |d| [d, d, pst, pen] }
      else
        [[s, e, pst, pen]]
      end
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
        pairs.each do |s, e, per_start, per_end|
          absence = HrAbsence.new(
            kind: permitted[:kind],
            reason: permitted[:reason],
            starts_on: s,
            ends_on:   e,
            first_day_half: first_half,
            last_day_half:  last_half,
            start_time: per_start,
            end_time:   per_end,
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
    unless can_delete?
      flash[:error] = l(:notice_hr_absence_forbidden)
      return respond_destroy
    end

    # Optional "chop" semantics for multi-day absences: when the request
    # carries on_date_from/on_date_to, we only remove that day range out of
    # the booking (splitting into two records if the chop sits in the middle).
    # Without those params the whole record goes.
    chop_from = parse_date(params[:on_date_from])
    chop_to   = parse_date(params[:on_date_to]) || chop_from
    if chop_from && chop_to
      chop_from, chop_to = chop_to, chop_from if chop_to < chop_from
      chop_from = @absence.starts_on if chop_from < @absence.starts_on
      chop_to   = @absence.ends_on   if chop_to   > @absence.ends_on
      if chop_from > @absence.ends_on || chop_to < @absence.starts_on
        return respond_destroy  # no overlap, nothing to do
      end
      if chop_from <= @absence.starts_on && chop_to >= @absence.ends_on
        @absence.destroy
        flash[:notice] = l(:notice_hr_absence_deleted)
      else
        chop_absence_day_range!(@absence, chop_from, chop_to)
        flash[:notice] = l(:notice_hr_absence_deleted)
      end
    else
      @absence.destroy
      flash[:notice] = l(:notice_hr_absence_deleted)
    end
    respond_destroy
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

  # Decode the `per_day` payload sent by the unified entry modal when the
  # user picked "pro Tag anpassen". Returns an array of
  # [date, date, start_time_hhmm, end_time_hhmm] tuples, one per calendar
  # day. Silently drops malformed entries.
  def parse_per_day_param
    raw = params[:per_day]
    return [] unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)
    hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    hash.filter_map do |date_str, times|
      date = parse_date(date_str)
      next unless date
      times = times.respond_to?(:to_unsafe_h) ? times.to_unsafe_h : times
      next unless times.is_a?(Hash)
      s = normalize_hhmm(times['start_time'] || times[:start_time])
      e = normalize_hhmm(times['end_time']   || times[:end_time])
      [date, date, s, e]
    end
  end

  # Remove a day range (chop_from..chop_to) from an absence that extends
  # strictly outside that range on at least one side. Three cases:
  #   • chop at the start → bump starts_on
  #   • chop at the end   → bump ends_on
  #   • chop in the middle → shrink original to the left half, create a new
  #     record for the right half (same kind, status, time windows cleared
  #     because partial-time absences are single-day by validation).
  def chop_absence_day_range!(absence, chop_from, chop_to)
    HrAbsence.transaction do
      left_end    = chop_from - 1
      right_start = chop_to   + 1
      has_left  = left_end    >= absence.starts_on
      has_right = right_start <= absence.ends_on

      prior_range = "#{absence.starts_on}..#{absence.ends_on}"
      if has_left && has_right
        # Split: keep the left part, clone the right part into a new record.
        right = absence.dup
        right.starts_on       = right_start
        right.ends_on         = absence.ends_on
        right.first_day_half  = false
        right.start_time      = nil
        right.end_time        = nil
        right.approved_by_id  = absence.approved_by_id
        right.approved_at     = absence.approved_at
        right.save!
        right.log_audit!(User.current, HrAbsenceAudit::ACTION_CREATED, to_status: right.status,
                         notes: "split-from ##{absence.id} (#{prior_range}, chop #{chop_from}..#{chop_to})")

        absence.ends_on       = left_end
        absence.last_day_half = false
        absence.save!
        absence.log_audit!(User.current, HrAbsenceAudit::ACTION_UPDATED, to_status: absence.status,
                           notes: "chop #{chop_from}..#{chop_to} (was #{prior_range})")
      elsif has_left
        absence.ends_on       = left_end
        absence.last_day_half = false
        absence.save!
        absence.log_audit!(User.current, HrAbsenceAudit::ACTION_UPDATED, to_status: absence.status,
                           notes: "chop tail #{chop_from}..#{chop_to} (was #{prior_range})")
      elsif has_right
        absence.starts_on      = right_start
        absence.first_day_half = false
        absence.save!
        absence.log_audit!(User.current, HrAbsenceAudit::ACTION_UPDATED, to_status: absence.status,
                           notes: "chop head #{chop_from}..#{chop_to} (was #{prior_range})")
      end
    end
  end

  def respond_destroy
    respond_to do |format|
      format.html { redirect_back(fallback_location: redirect_target) }
      format.json { render json: { ok: true } }
    end
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

  # Owner may always delete:
  #   • anything in the future (ends_on >= today) — mistakes get fixed,
  #   • every self-service kind regardless of status (workday/homeoffice/care
  #     and the kinds can_edit? already covers).
  # Approved past vacation stays admin-only (HR-tracked).
  def can_delete?
    return true if User.current.admin?
    return false unless owner?
    return true if @absence.ends_on && @absence.ends_on >= Date.current
    return true if @absence.workday? || @absence.homeoffice? || @absence.care?
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

  # When the modal carries an explicit return_to path (admin context), use it
  # — otherwise fall back to the personal timeclock as before. Same-origin
  # only, so admins who create entries from /admin/hr_timeclock land back
  # there instead of being kicked to their own page.
  def safe_return_to
    raw = params[:return_to].to_s
    return nil unless raw.start_with?('/')
    raw
  end

  def respond_create_failure(message)
    respond_to do |format|
      format.html do
        flash[:error] = message
        target = safe_return_to
        target ? redirect_to(target) : redirect_back(fallback_location: hr_timeclock_path)
      end
      format.json { render json: { error: message }, status: :unprocessable_entity }
    end
  end

  def respond_create_success(message)
    respond_to do |format|
      format.html do
        flash[:notice] = message if message.present?
        target = safe_return_to
        target ? redirect_to(target) : redirect_back(fallback_location: hr_timeclock_path)
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
