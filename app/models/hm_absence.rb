class HmAbsence < ActiveRecord::Base
  self.table_name = 'hm_absences'

  KIND_VACATION = 'vacation'.freeze
  KIND_SICKNESS = 'sickness'.freeze
  KIND_OFFSITE  = 'offsite'.freeze
  KINDS         = [KIND_VACATION, KIND_SICKNESS, KIND_OFFSITE].freeze
  USER_BACKDATE_LIMIT_DAYS = 3

  AUTO_APPROVED_KINDS = [KIND_SICKNESS, KIND_OFFSITE].freeze

  STATUS_REQUESTED = 'requested'.freeze
  STATUS_APPROVED  = 'approved'.freeze
  STATUS_REJECTED  = 'rejected'.freeze
  STATUSES         = [STATUS_REQUESTED, STATUS_APPROVED, STATUS_REJECTED].freeze

  belongs_to :user
  belongs_to :approver, class_name: 'User', foreign_key: 'approved_by_id', optional: true
  has_many :audits, -> { order(:created_at) }, class_name: 'HmAbsenceAudit', dependent: :destroy

  validates :kind,   inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :starts_on, :ends_on, presence: true
  validate  :ends_after_starts

  scope :for_user,  ->(u) { where(user_id: u.is_a?(User) ? u.id : u.to_i) }
  scope :vacation,  -> { where(kind: KIND_VACATION) }
  scope :sickness,  -> { where(kind: KIND_SICKNESS) }
  scope :offsite,   -> { where(kind: KIND_OFFSITE) }
  scope :counted,   -> { where(kind: [KIND_VACATION, KIND_SICKNESS]) }
  scope :pending,   -> { where(status: STATUS_REQUESTED) }
  scope :approved,  -> { where(status: STATUS_APPROVED) }
  scope :rejected,  -> { where(status: STATUS_REJECTED) }
  scope :active,    -> { where(status: [STATUS_REQUESTED, STATUS_APPROVED]) }
  scope :overlapping, ->(from, to) { where('starts_on <= ? AND ends_on >= ?', to, from) }

  def vacation?;  kind == KIND_VACATION; end
  def sickness?;  kind == KIND_SICKNESS; end
  def offsite?;   kind == KIND_OFFSITE;  end
  def auto_approved?; AUTO_APPROVED_KINDS.include?(kind); end
  def requested?; status == STATUS_REQUESTED; end
  def approved?;  status == STATUS_APPROVED; end
  def rejected?;  status == STATUS_REJECTED; end
  def pending?;   requested?; end

  def days
    return 0 if starts_on.blank? || ends_on.blank?
    (ends_on - starts_on).to_i + 1
  end

  def includes_date?(date)
    starts_on <= date && date <= ends_on
  end

  def conflicts(padding_days: 7)
    return self.class.none if starts_on.blank? || ends_on.blank?
    from = starts_on - padding_days
    to   = ends_on   + padding_days
    self.class.vacation.approved
              .where.not(id: id)
              .where.not(user_id: user_id)
              .where('starts_on <= ? AND ends_on >= ?', to, from)
              .includes(:user)
              .order(:starts_on)
  end

  def breakdown
    ::RedmineHmCratchmere::Holidays.breakdown(starts_on, ends_on)
  end

  def self.kind_label(kind)
    case kind
    when KIND_VACATION then I18n.t(:label_hm_hr_vacation)
    when KIND_SICKNESS then I18n.t(:label_hm_hr_sickness)
    when KIND_OFFSITE  then I18n.t(:label_hm_hr_offsite)
    else kind.to_s.humanize
    end
  end

  # Kinds whose ranges must not overlap with any other entry of the same kind
  # for the same user (excluding rejected entries).
  EXCLUSIVE_KINDS = [KIND_VACATION, KIND_SICKNESS].freeze

  def self.overlapping_for(user_id, kind, starts_on, ends_on, exclude_id: nil)
    return self.none unless EXCLUSIVE_KINDS.include?(kind)
    return self.none if starts_on.blank? || ends_on.blank?
    scope = for_user(user_id).where(kind: kind).active
                             .where('starts_on <= ? AND ends_on >= ?', ends_on, starts_on)
    scope = scope.where.not(id: exclude_id) if exclude_id
    scope
  end

  # Validation gates that apply to *every* requester (admin included)
  def self.validate_kind_window(kind, starts_on, ends_on, today = Date.current)
    case kind
    when KIND_SICKNESS
      # Start must lie on or before today (no fully-future planning), but ends_on may
      # extend into the future to cover an AU-Bescheinigung that signs forward.
      return :future_start_not_allowed if starts_on && starts_on > today
    when KIND_OFFSITE
      # Off-site is planning-friendly — trips can be scheduled months ahead.
      nil
    end
    nil
  end

  RECURRENCE_NONE       = 'none'.freeze
  RECURRENCE_WEEKLY     = 'weekly'.freeze
  RECURRENCE_BIWEEKLY   = 'biweekly'.freeze
  RECURRENCE_4_WEEKLY   = 'four_weekly'.freeze
  RECURRENCE_MONTHLY    = 'monthly'.freeze
  RECURRENCE_QUARTERLY  = 'quarterly'.freeze
  RECURRENCE_HALFYEARLY = 'half_yearly'.freeze
  RECURRENCE_YEARLY     = 'yearly'.freeze
  RECURRENCES = [RECURRENCE_NONE, RECURRENCE_WEEKLY, RECURRENCE_BIWEEKLY,
                 RECURRENCE_4_WEEKLY, RECURRENCE_MONTHLY, RECURRENCE_QUARTERLY,
                 RECURRENCE_HALFYEARLY, RECURRENCE_YEARLY].freeze

  RECURRENCE_LIMIT = 200 # safety cap so a year of weekly recurrence stays bounded

  def self.recurrence_label(kind)
    case kind
    when RECURRENCE_WEEKLY     then I18n.t(:label_hm_recurrence_weekly)
    when RECURRENCE_BIWEEKLY   then I18n.t(:label_hm_recurrence_biweekly)
    when RECURRENCE_4_WEEKLY   then I18n.t(:label_hm_recurrence_four_weekly)
    when RECURRENCE_MONTHLY    then I18n.t(:label_hm_recurrence_monthly)
    when RECURRENCE_QUARTERLY  then I18n.t(:label_hm_recurrence_quarterly)
    when RECURRENCE_HALFYEARLY then I18n.t(:label_hm_recurrence_half_yearly)
    when RECURRENCE_YEARLY     then I18n.t(:label_hm_recurrence_yearly)
    else I18n.t(:label_hm_recurrence_none)
    end
  end

  # Advance a (start, end) range by one step of `kind`. Returns nil if kind is :none.
  def self.recurrence_step(kind, starts_on, ends_on)
    return nil unless kind && kind != RECURRENCE_NONE
    case kind
    when RECURRENCE_WEEKLY     then [starts_on +  7,            ends_on +  7]
    when RECURRENCE_BIWEEKLY   then [starts_on + 14,            ends_on + 14]
    when RECURRENCE_4_WEEKLY   then [starts_on + 28,            ends_on + 28]
    when RECURRENCE_MONTHLY    then [starts_on >> 1,            ends_on >> 1]
    when RECURRENCE_QUARTERLY  then [starts_on >> 3,            ends_on >> 3]
    when RECURRENCE_HALFYEARLY then [starts_on >> 6,            ends_on >> 6]
    when RECURRENCE_YEARLY     then [starts_on >> 12,           ends_on >> 12]
    end
  end

  # Returns an array of [starts_on, ends_on] pairs including the base occurrence.
  def self.expand_recurrence(starts_on, ends_on, kind, until_on)
    pairs = [[starts_on, ends_on]]
    return pairs if kind.blank? || kind == RECURRENCE_NONE || until_on.blank?
    return pairs unless RECURRENCES.include?(kind)
    cur_s, cur_e = starts_on, ends_on
    RECURRENCE_LIMIT.times do
      step = recurrence_step(kind, cur_s, cur_e)
      break unless step
      cur_s, cur_e = step
      break if cur_s > until_on
      pairs << [cur_s, cur_e]
    end
    pairs
  end

  # Additional gates that only apply to non-admin users
  def self.validate_user_window(kind, starts_on, ends_on, today = Date.current)
    hard = validate_kind_window(kind, starts_on, ends_on, today)
    return hard if hard
    if kind == KIND_SICKNESS && starts_on && (today - starts_on).to_i > USER_BACKDATE_LIMIT_DAYS
      return :backdate_exceeded
    end
    nil
  end

  def self.status_label(status)
    case status
    when STATUS_REQUESTED then I18n.t(:label_hm_absence_status_requested)
    when STATUS_APPROVED  then I18n.t(:label_hm_absence_status_approved)
    when STATUS_REJECTED  then I18n.t(:label_hm_absence_status_rejected)
    else status.to_s.humanize
    end
  end

  def log_audit!(actor, action, from_status: nil, to_status: nil, notes: nil)
    HmAbsenceAudit.create!(
      hm_absence_id: id,
      actor_id: actor.id,
      action: action,
      from_status: from_status,
      to_status:   to_status,
      notes:       notes
    )
  rescue StandardError => e
    Rails.logger.warn("[hm_cratchmere] failed to log audit: #{e.message}") if defined?(Rails)
    nil
  end

  def approve_by!(actor, notes: nil)
    prior = status
    transaction do
      update!(status: STATUS_APPROVED, approved_by_id: actor.id, approved_at: Time.current)
      log_audit!(actor, HmAbsenceAudit::ACTION_APPROVED, from_status: prior, to_status: STATUS_APPROVED, notes: notes)
    end
  end

  def reject_by!(actor, notes: nil)
    prior = status
    transaction do
      update!(status: STATUS_REJECTED, approved_by_id: actor.id, approved_at: Time.current)
      log_audit!(actor, HmAbsenceAudit::ACTION_REJECTED, from_status: prior, to_status: STATUS_REJECTED, notes: notes)
    end
  end

  def self.build_by_day(absences, range_from, range_to)
    result = Hash.new { |h, k| h[k] = [] }
    absences.each do |a|
      from = [a.starts_on, range_from].max
      to   = [a.ends_on,   range_to].min
      next if from > to
      (from..to).each { |d| result[d] << a }
    end
    result
  end

  private

  def ends_after_starts
    return if starts_on.blank? || ends_on.blank?
    errors.add(:ends_on, :greater_than_or_equal_to) if ends_on < starts_on
  end
end
