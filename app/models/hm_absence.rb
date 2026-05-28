class HmAbsence < ActiveRecord::Base
  self.table_name = 'hr_absences'

  KIND_VACATION   = 'vacation'.freeze
  KIND_SICKNESS   = 'sickness'.freeze
  KIND_OFFSITE    = 'offsite'.freeze
  KIND_SCHOOL     = 'school'.freeze    # Berufsschule / Prüfung (self-service, recurring)
  KIND_BLOCK      = 'blocked'.freeze   # geblockter Tag mit Grund, z.B. Vorlesung (variable Stellen)
  KIND_HOMEOFFICE = 'homeoffice'.freeze
  KIND_CARE       = 'care'.freeze      # Betreuungszeit (§45 SGB V) — krankes Kind
  KINDS           = [KIND_VACATION, KIND_SICKNESS, KIND_OFFSITE, KIND_SCHOOL, KIND_BLOCK,
                     KIND_HOMEOFFICE, KIND_CARE].freeze
  USER_BACKDATE_LIMIT_DAYS = 3

  AUTO_APPROVED_KINDS = [KIND_SICKNESS, KIND_OFFSITE, KIND_SCHOOL, KIND_BLOCK].freeze
  # Kinds that the user may freely plan into the future with a recurrence interval.
  RECURRENCE_CAPABLE_KINDS = [KIND_OFFSITE, KIND_SCHOOL, KIND_BLOCK, KIND_HOMEOFFICE].freeze
  # Kinds that mark a day as non-working (daily target becomes 0).
  BLOCKING_KINDS = [KIND_SCHOOL, KIND_BLOCK].freeze
  # "Working elsewhere" markers: the person is still working, just not in the
  # office, so these never reduce the day's target. Offsite (Auswärtstätigkeit)
  # and homeoffice are informational only — tracked hours must count as normal
  # work, not overtime. Care, by contrast, is genuine time off and does reduce.
  NON_REDUCING_KINDS = [KIND_OFFSITE, KIND_HOMEOFFICE].freeze

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
  validate  :time_range_consistent

  scope :for_user,    ->(u) { where(user_id: u.is_a?(User) ? u.id : u.to_i) }
  scope :vacation,    -> { where(kind: KIND_VACATION) }
  scope :sickness,    -> { where(kind: KIND_SICKNESS) }
  scope :offsite,     -> { where(kind: KIND_OFFSITE) }
  scope :school,      -> { where(kind: KIND_SCHOOL) }
  scope :blocked,     -> { where(kind: KIND_BLOCK) }
  scope :homeoffice,  -> { where(kind: KIND_HOMEOFFICE) }
  scope :care,        -> { where(kind: KIND_CARE) }
  scope :blocking,    -> { where(kind: BLOCKING_KINDS) }
  scope :counted,     -> { where(kind: [KIND_VACATION, KIND_SICKNESS]) }
  scope :pending,   -> { where(status: STATUS_REQUESTED) }
  scope :approved,  -> { where(status: STATUS_APPROVED) }
  scope :rejected,  -> { where(status: STATUS_REJECTED) }
  scope :active,    -> { where(status: [STATUS_REQUESTED, STATUS_APPROVED]) }
  scope :overlapping, ->(from, to) { where('starts_on <= ? AND ends_on >= ?', to, from) }

  def vacation?;   kind == KIND_VACATION;   end
  def sickness?;   kind == KIND_SICKNESS;   end
  def offsite?;    kind == KIND_OFFSITE;    end
  def school?;     kind == KIND_SCHOOL;     end
  def blocked?;    kind == KIND_BLOCK;      end
  def homeoffice?; kind == KIND_HOMEOFFICE; end
  def care?;       kind == KIND_CARE;       end
  def auto_approved?; AUTO_APPROVED_KINDS.include?(kind); end
  def requested?; status == STATUS_REQUESTED; end
  def approved?;  status == STATUS_APPROVED; end
  def rejected?;  status == STATUS_REJECTED; end
  def pending?;   requested?; end

  def days
    return 0 if starts_on.blank? || ends_on.blank?
    (ends_on - starts_on).to_i + 1
  end

  # A partial-time absence covers only a sub-window of a single day.
  def partial?
    start_time.present? && end_time.present?
  end

  # Minutes covered on a given calendar date. Returns 0 if the day isn't in the
  # absence range or the time fields are unset on a single-day partial.
  def partial_minutes_on(date)
    return 0 unless partial?
    return 0 unless includes_date?(date) && starts_on == date && ends_on == date
    s = parse_hhmm(start_time)
    e = parse_hhmm(end_time)
    return 0 if s.nil? || e.nil? || e <= s
    e - s
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

  def region_code
    @region_code ||= HmUserSetting.for(user).effective_region_code if user
  end

  def breakdown
    ::RedmineHumanResources::Holidays.breakdown(starts_on, ends_on, region_code: region_code)
  end

  # Fractional working-day count for this absence within an optional clamp range,
  # honouring half-day flags on the first/last day.
  def working_days_value(from: nil, to: nil, region_code: nil)
    return 0.0 if starts_on.blank? || ends_on.blank?
    rc = region_code || self.region_code
    s = from ? [starts_on, from].max : starts_on
    e = to   ? [ends_on,   to].min   : ends_on
    return 0.0 if s > e
    count = ::RedmineHumanResources::Holidays.breakdown(s, e, region_code: rc)[:working].to_f
    if first_day_half? && starts_on >= s && starts_on <= e &&
       ::RedmineHumanResources::Holidays.working_day?(starts_on, region_code: rc)
      count -= 0.5
    end
    if last_day_half? && ends_on != starts_on && ends_on >= s && ends_on <= e &&
       ::RedmineHumanResources::Holidays.working_day?(ends_on, region_code: rc)
      count -= 0.5
    end
    [count, 0.0].max
  end

  def self.kind_label(kind)
    case kind
    when KIND_VACATION   then I18n.t(:label_hm_hr_vacation)
    when KIND_SICKNESS   then I18n.t(:label_hm_hr_sickness)
    when KIND_OFFSITE    then I18n.t(:label_hm_hr_offsite)
    when KIND_SCHOOL     then I18n.t(:label_hm_hr_school)
    when KIND_BLOCK      then I18n.t(:label_hm_hr_block)
    when KIND_HOMEOFFICE then I18n.t(:label_hm_hr_homeoffice)
    when KIND_CARE       then I18n.t(:label_hm_hr_care)
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
    Rails.logger.warn("[hr] failed to log audit: #{e.message}") if defined?(Rails)
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

  # Counts working days of approved vacation entries that overlap with the given
  # year. Half-day flags reduce a day to 0.5; result may be fractional.
  def self.vacation_working_days_used(user_id, year = Date.current.year)
    year_start = Date.new(year, 1, 1)
    year_end   = Date.new(year, 12, 31)
    region = HmUserSetting.for(User.find(user_id)).effective_region_code rescue nil
    total = for_user(user_id).vacation.approved
                     .where('starts_on <= ? AND ends_on >= ?', year_end, year_start)
                     .sum do |a|
      a.working_days_value(from: year_start, to: year_end, region_code: region)
    end
    # Trim floating-point noise.
    (total * 2).round / 2.0
  end

  def self.vacation_remaining(user, year = Date.current.year)
    setting = HmUserSetting.for(user)
    allowed = setting.effective_yearly_vacation_days.to_i
    used = vacation_working_days_used(user.is_a?(User) ? user.id : user.to_i, year)
    { allowed: allowed, used: used, remaining: (allowed - used) }
  end

  # Sum of working days of approved homeoffice entries within a year.
  def self.homeoffice_working_days_used(user_id, year = Date.current.year)
    year_start = Date.new(year, 1, 1)
    year_end   = Date.new(year, 12, 31)
    region = HmUserSetting.for(User.find(user_id)).effective_region_code rescue nil
    total = for_user(user_id).homeoffice.approved
                     .where('starts_on <= ? AND ends_on >= ?', year_end, year_start)
                     .sum { |a| a.working_days_value(from: year_start, to: year_end, region_code: region) }
    (total * 2).round / 2.0
  end

  def self.homeoffice_remaining(user, year = Date.current.year)
    setting = HmUserSetting.for(user)
    allowed = setting.effective_homeoffice_days_per_year.to_i
    used = homeoffice_working_days_used(user.is_a?(User) ? user.id : user.to_i, year)
    { allowed: allowed, used: used, remaining: (allowed - used) }
  end

  # Care quota is tracked in MINUTES. A full-day entry counts the user's base
  # daily target as consumed minutes; a partial entry counts the explicit
  # start/end window.
  def care_consumed_minutes
    return 0 unless care?
    setting = HmUserSetting.for(user) if user
    daily = setting ? setting.base_daily_target_minutes : 480
    total = 0
    (starts_on..ends_on).each do |d|
      if partial? && starts_on == d
        total += partial_minutes_on(d)
      else
        total += daily
      end
    end
    total
  end

  def self.care_minutes_used(user_id, year = Date.current.year)
    year_start = Date.new(year, 1, 1)
    year_end   = Date.new(year, 12, 31)
    for_user(user_id).care.approved
             .where('starts_on <= ? AND ends_on >= ?', year_end, year_start)
             .sum(&:care_consumed_minutes)
  end

  def self.care_remaining(user, year = Date.current.year)
    setting = HmUserSetting.for(user)
    allowed_hours = setting.effective_care_hours_per_year.to_i
    allowed_min   = allowed_hours * 60
    used_min      = care_minutes_used(user.is_a?(User) ? user.id : user.to_i, year)
    { allowed_minutes: allowed_min, used_minutes: used_min, remaining_minutes: (allowed_min - used_min) }
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

  def parse_hhmm(value)
    return nil if value.blank?
    m = value.to_s.match(/\A(\d{1,2}):(\d{2})\z/)
    return nil unless m
    h = m[1].to_i
    mm = m[2].to_i
    return nil if h.negative? || h > 24 || mm.negative? || mm > 59
    h * 60 + mm
  end

  def time_range_consistent
    return if start_time.blank? && end_time.blank?
    if start_time.blank? || end_time.blank?
      errors.add(:base, :hm_absence_time_range_incomplete) and return
    end
    s = parse_hhmm(start_time)
    e = parse_hhmm(end_time)
    if s.nil? || e.nil?
      errors.add(:base, :hm_absence_time_range_invalid) and return
    end
    errors.add(:base, :hm_absence_time_range_order) if e <= s
    errors.add(:base, :hm_absence_time_range_single_day) if starts_on && ends_on && starts_on != ends_on
  end
end
