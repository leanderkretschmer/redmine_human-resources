class HrMonthlyPlan < ActiveRecord::Base
  self.table_name = 'hr_monthly_plans'

  belongs_to :user
  belongs_to :created_by, class_name: 'User', optional: true

  validates :user_id,        presence: true
  validates :year,           presence: true, numericality: { only_integer: true, greater_than: 2000, less_than: 3000 }
  validates :month,          presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 12 }
  validates :target_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :user_id, uniqueness: { scope: [:year, :month] }

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :for_period, ->(year, month) { where(year: year, month: month) }

  def self.target_for(user, date)
    plan = for_user(user).for_period(date.year, date.month).first
    plan&.target_minutes
  end

  def starts_on
    Date.new(year, month, 1)
  end

  def ends_on
    starts_on.end_of_month
  end

  def working_days
    setting = HrUserSetting.for(user)
    school_days = setting.effective_weekly_school_days.to_i
    work_days_per_week = [5 - school_days, 0].max
    return 0 if work_days_per_week.zero?

    (starts_on..ends_on).count do |d|
      d.wday >= 1 && d.wday <= work_days_per_week
    end
  end

  def daily_target_minutes
    days = working_days
    return 0 if days.zero?
    (target_minutes.to_f / days).round
  end
end
