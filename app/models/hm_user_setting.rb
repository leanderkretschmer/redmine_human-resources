class HmUserSetting < ActiveRecord::Base
  self.table_name = 'hm_user_settings'

  belongs_to :user
  belongs_to :hm_employment_type, optional: true

  validates :user_id, uniqueness: true
  validates :daily_target_minutes,           numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weekly_target_minutes,          numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :max_break_minutes,              numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :yearly_vacation_days_override,  numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weekly_school_days_override,    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5, allow_nil: true }

  def self.for(user)
    rec = find_or_initialize_by(user_id: user.id)
    rec.save!(validate: false) if rec.new_record?
    rec
  end

  # ── Effective values: own override → template → plugin default → hardcoded fallback ──

  def effective_daily_target_minutes(on_date: nil)
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

  def effective_weekly_target_minutes(on_date: nil)
    if on_date && allows_monthly_plan?
      plan = HmMonthlyPlan.for_user(user).for_period(on_date.year, on_date.month).first
      return (plan.target_minutes / 4.345).round if plan && plan.target_minutes.positive?
    end
    positive_or_nil(weekly_target_minutes) ||
      positive_or_nil(template_value(:weekly_target_minutes)) ||
      plugin_default(:default_weekly_target_minutes, 2400)
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
    settings = Setting.plugin_redmine_hm_cratchmere || {}
    val = settings[key.to_s]
    val.to_i.positive? ? val.to_i : fallback
  end
end
