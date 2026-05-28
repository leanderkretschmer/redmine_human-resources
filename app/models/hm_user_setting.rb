class HmUserSetting < ActiveRecord::Base
  self.table_name = 'hr_user_settings'

  # Care quota tiers (anonymised in the UI as "Betreuung X/Y Stunden"). The
  # actual annual quota in hours is admin-configured per tier and per user.
  CARE_STATUS_COUPLE = 'couple'.freeze   # § 45 SGB V: pro Elternteil, gepaartes Elternpaar
  CARE_STATUS_SINGLE = 'single'.freeze   # alleinerziehend, doppeltes Stundenkontingent
  CARE_STATUSES      = [CARE_STATUS_COUPLE, CARE_STATUS_SINGLE].freeze

  belongs_to :user
  belongs_to :hm_employment_type, optional: true

  validates :user_id, uniqueness: true
  validates :daily_target_minutes,                numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weekly_target_minutes,               numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :max_break_minutes,                   numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :yearly_vacation_days_override,       numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weekly_school_days_override,         numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5, allow_nil: true }
  validates :homeoffice_days_per_year_override,   numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :care_hours_per_year_override,        numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :care_status, inclusion: { in: CARE_STATUSES, allow_nil: true }

  def self.for(user)
    rec = find_or_initialize_by(user_id: user.id)
    rec.save!(validate: false) if rec.new_record?
    rec
  end

  # ── Effective values: own override → template → plugin default → hardcoded fallback ──

  def effective_daily_target_minutes(on_date: nil)
    base = base_daily_target_minutes(on_date: on_date)
    return base unless on_date
    # Partial-time absences (e.g. sick 08:00–14:30) reduce that day's target by
    # exactly the covered minutes, so the user only needs to make up the rest.
    reduced = base - partial_absence_minutes_on(on_date)
    [reduced, 0].max
  end

  def base_daily_target_minutes(on_date: nil)
    # A self-service blocked day (Berufsschule, Vorlesung, …) frees the day.
    return 0 if on_date && blocked_day?(on_date)

    if on_date
      period = active_lecture_period(on_date)
      return period.daily_minutes_for(on_date) if period
    end

    if on_date && allows_monthly_plan?
      plan_daily = HmMonthlyPlan.for_user(user).for_period(on_date.year, on_date.month).first
      return plan_daily.daily_target_minutes if plan_daily && plan_daily.daily_target_minutes.positive?
    end

    base = positive_or_nil(daily_target_minutes) ||
           positive_or_nil(template_value(:daily_target_minutes)) ||
           plugin_default(:default_daily_target_minutes, 480)

    return base unless on_date
    weekdays = effective_school_weekdays
    return base unless weekdays.any?

    return 0 if on_date.cwday > 5
    return base unless weekdays.include?(on_date.cwday)

    weekly = positive_or_nil(weekly_target_minutes) ||
             positive_or_nil(template_value(:weekly_target_minutes)) ||
             plugin_default(:default_weekly_target_minutes, 2400)
    work_days_per_week = [5 - weekdays.size, 0].max
    partial = weekly - (work_days_per_week * base)
    return 0 if partial <= 0
    partial_day = weekdays.min
    on_date.cwday == partial_day ? [partial, base].min : 0
  end

  def partial_absence_minutes_on(date)
    return 0 unless date && user
    HmAbsence.for_user(user).active
             .where(starts_on: date, ends_on: date)
             .where.not(start_time: nil).where.not(end_time: nil)
             .to_a.sum { |a| a.partial_minutes_on(date) }
  rescue ActiveRecord::StatementInvalid, NameError
    0
  end

  def effective_weekly_target_minutes(on_date: nil)
    if on_date
      period = active_lecture_period(on_date)
      if period
        return period.weekly_target_minutes.to_i if period.weekly_target_minutes.to_i.positive?
        return period.daily_target_minutes.to_i * 5 if period.daily_target_minutes.to_i.positive?
        return 0
      end
    end
    if on_date && allows_monthly_plan?
      plan = HmMonthlyPlan.for_user(user).for_period(on_date.year, on_date.month).first
      return (plan.target_minutes / 4.345).round if plan && plan.target_minutes.positive?
    end
    positive_or_nil(weekly_target_minutes) ||
      positive_or_nil(template_value(:weekly_target_minutes)) ||
      plugin_default(:default_weekly_target_minutes, 2400)
  end

  def active_lecture_period(date)
    return nil unless date
    HmLecturePeriod.for_user(user).covering(date).first
  rescue ActiveRecord::StatementInvalid, NameError
    nil
  end

  def blocked_day?(date)
    return false unless date && user
    HmAbsence.for_user(user).active.blocking
             .where('starts_on <= :d AND ends_on >= :d', d: date).exists?
  rescue ActiveRecord::StatementInvalid, NameError
    false
  end

  # Eligible for the self-service planning calendar:
  # variable employment (Werkstudent/Praktikum) or a vocational-school setup.
  def planning_eligible?
    allows_monthly_plan? || effective_weekly_school_days.to_i.positive? ||
      effective_school_weekdays.any?
  end

  def planning_kinds
    kinds = []
    kinds << HmAbsence::KIND_SCHOOL if effective_weekly_school_days.to_i.positive? || effective_school_weekdays.any?
    kinds << HmAbsence::KIND_BLOCK  if allows_monthly_plan?
    kinds = [HmAbsence::KIND_BLOCK, HmAbsence::KIND_SCHOOL] if kinds.empty? && planning_eligible?
    kinds
  end

  def effective_max_break_minutes
    return max_break_minutes unless max_break_minutes.nil?
    tmpl = template_value(:max_break_minutes)
    return tmpl unless tmpl.nil?
    plugin_default(:default_max_break_minutes, 60)
  end

  def effective_yearly_vacation_days
    return yearly_vacation_days_override unless yearly_vacation_days_override.nil?
    template_value(:yearly_vacation_days) || 20
  end

  def effective_homeoffice_days_per_year
    return homeoffice_days_per_year_override unless homeoffice_days_per_year_override.nil?
    plugin_default(:default_homeoffice_days_per_year, 0)
  end

  # Care quota in hours. If admin set a per-user override, that wins. Otherwise
  # the plugin defaults provide a value keyed by care_status (couple vs single).
  def effective_care_hours_per_year
    return care_hours_per_year_override unless care_hours_per_year_override.nil?
    case care_status
    when CARE_STATUS_COUPLE then plugin_default(:default_care_hours_couple, 0)
    when CARE_STATUS_SINGLE then plugin_default(:default_care_hours_single, 0)
    else 0
    end
  end

  # The "Betreuungszeit" menu entry is hidden unless the admin has assigned a
  # care_status to this user.
  def care_visible?
    CARE_STATUSES.include?(care_status)
  end

  def effective_weekly_school_days
    wd = effective_school_weekdays
    return wd.size if wd.any?
    return weekly_school_days_override unless weekly_school_days_override.nil?
    template_value(:weekly_school_days) || 0
  end

  # Returns array of cwday integers (1=Mon ... 5=Fri) representing school days.
  def effective_school_weekdays
    own = parse_weekdays(school_weekdays_override)
    return own if own.any? || !school_weekdays_override.nil?
    parse_weekdays(template_value(:school_weekdays_pattern))
  end

  # Distribution helper. Given total weekly company minutes and full-day minutes,
  # returns a breakdown: { full_days:, partial_minutes:, partial_present:, free_minutes:, total_workdays:, school_days: }
  def hour_distribution(weekly_minutes = nil, daily_minutes = nil)
    w = (weekly_minutes || effective_weekly_target_minutes).to_i
    d = (daily_minutes  || effective_daily_target_minutes).to_i
    return nil if w <= 0 || d <= 0
    s = effective_weekly_school_days.to_i
    work_days_max = [5 - s, 0].max
    full   = [w / d, work_days_max].min
    filled = full * d
    partial = w - filled
    partial = 0 if partial.negative?
    partial = d if partial > d
    {
      full_days:       full,
      partial_minutes: partial,
      partial_present: partial.positive?,
      free_minutes:    partial.positive? ? (d - partial) : 0,
      total_workdays:  full + (partial.positive? ? 1 : 0),
      school_days:     s
    }
  end

  def allows_monthly_plan?
    return allows_monthly_plan_override unless allows_monthly_plan_override.nil?
    !!template_value(:allows_monthly_plan)
  end

  # Region code (e.g. "DE-BW") used for state-specific public holidays.
  def effective_region_code
    region_code.presence
  end

  def monthly_plan_for(date)
    HmMonthlyPlan.for_user(user).for_period(date.year, date.month).first
  end

  private

  def parse_weekdays(value)
    return [] if value.blank?
    value.to_s.split(/[,;\s]+/).map { |s| s.to_i }.select { |i| i.between?(1, 5) }.uniq.sort
  end

  def template_value(attr)
    hm_employment_type&.read_attribute(attr)
  end

  def positive_or_nil(value)
    value.to_i.positive? ? value.to_i : nil
  end

  def plugin_default(key, fallback)
    settings = Setting.plugin_redmine_human_resources || {}
    val = settings[key.to_s]
    val.to_i.positive? ? val.to_i : fallback
  end
end
