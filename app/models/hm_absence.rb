class HmAbsence < ActiveRecord::Base
  self.table_name = 'hm_absences'

  KIND_VACATION = 'vacation'.freeze
  KIND_SICKNESS = 'sickness'.freeze
  KINDS         = [KIND_VACATION, KIND_SICKNESS].freeze

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
  scope :pending,   -> { where(status: STATUS_REQUESTED) }
  scope :approved,  -> { where(status: STATUS_APPROVED) }
  scope :rejected,  -> { where(status: STATUS_REJECTED) }
  scope :active,    -> { where(status: [STATUS_REQUESTED, STATUS_APPROVED]) }
  scope :overlapping, ->(from, to) { where('starts_on <= ? AND ends_on >= ?', to, from) }

  def vacation?;  kind == KIND_VACATION; end
  def sickness?;  kind == KIND_SICKNESS; end
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
    else kind.to_s.humanize
    end
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
