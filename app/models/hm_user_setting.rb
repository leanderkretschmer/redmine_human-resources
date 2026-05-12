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
    positive_or_nil(daily_target_minutes) ||
      positive_or_nil(template_value(:daily_target_minutes)) ||
      plugin_default(:default_daily_target_minutes, 480)
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
    return weekly_school_days_override unless weekly_school_days_override.nil?
    template_value(:weekly_school_days) || 0
  end

  def allows_monthly_plan?
    return allows_monthly_plan_override unless allows_monthly_plan_override.nil?
    !!template_value(:allows_monthly_plan)
  end

  def monthly_plan_for(date)
    HmMonthlyPlan.for_user(user).for_period(date.year, date.month).first
  end

  private

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
