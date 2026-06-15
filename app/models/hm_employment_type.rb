class HmEmploymentType < ActiveRecord::Base
  self.table_name = 'hr_employment_types'

  has_many :hm_user_settings, foreign_key: :hm_employment_type_id, dependent: :nullify

  validates :name, presence: true, length: { maximum: 80 }
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9_\-]+\z/ }
  validates :max_break_minutes,    numericality: { greater_than_or_equal_to: 0 }
  validates :yearly_vacation_days, numericality: { greater_than_or_equal_to: 0 }
  validates :weekly_school_days,   numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5 }

  scope :active,  -> { where(archived: false) }
  scope :ordered, -> { order(:position_order, :name) }

  LEGAL_DEFAULTS = [
    {
      slug: 'fulltime_40',
      name: 'Vollzeit 40h',
      weekly_target_minutes: 2400, daily_target_minutes: 480,
      max_break_minutes: 30, yearly_vacation_days: 20, weekly_school_days: 0,
      allows_monthly_plan: false, position_order: 10,
      description: 'Vollzeitstelle 40h/Woche, 5-Tage-Woche. Pause 30 min nach ArbZG §4.'
    },
    {
      slug: 'auszubildender',
      name: 'Auszubildender',
      weekly_target_minutes: 1920, daily_target_minutes: 480,
      max_break_minutes: 30, yearly_vacation_days: 20, weekly_school_days: 1,
      school_weekdays_pattern: '',
      allows_monthly_plan: false, position_order: 11,
      description: 'Ausbildungsstelle. Berufsschultage und Wochenstunden werden je Person eingestellt (Override pro Nutzer).'
    },
    {
      slug: 'parttime_30',
      name: 'Teilzeit 30h',
      weekly_target_minutes: 1800, daily_target_minutes: 360,
      max_break_minutes: 30, yearly_vacation_days: 20, weekly_school_days: 0,
      allows_monthly_plan: false, position_order: 20,
      description: 'Teilzeit 30h/Woche, 5-Tage-Woche. Pause 30 min ab 6h.'
    },
    {
      slug: 'parttime_20',
      name: 'Teilzeit 20h',
      weekly_target_minutes: 1200, daily_target_minutes: 240,
      max_break_minutes: 0, yearly_vacation_days: 20, weekly_school_days: 0,
      allows_monthly_plan: false, position_order: 21,
      description: 'Teilzeit 20h/Woche, 5-Tage-Woche. Keine gesetzliche Pausenpflicht <6h.'
    },
    {
      slug: 'werkstudent',
      name: 'Werkstudent:in',
      weekly_target_minutes: 1200, daily_target_minutes: nil,
      max_break_minutes: 0, yearly_vacation_days: 20, weekly_school_days: 0,
      allows_monthly_plan: true, position_order: 30,
      description: 'Werkstudent:in mit max. 20h/Woche während der Vorlesungszeit. Pensum monatlich planbar.'
    },
    {
      slug: 'intern',
      name: 'Praktikant:in',
      weekly_target_minutes: nil, daily_target_minutes: nil,
      max_break_minutes: 30, yearly_vacation_days: 0, weekly_school_days: 0,
      allows_monthly_plan: true, position_order: 40,
      description: 'Praktikumsstelle ohne festes Wochenpensum. Soll wird monatlich geplant.'
    },
    {
      slug: 'freelancer',
      name: 'Freelancer',
      weekly_target_minutes: nil, daily_target_minutes: nil,
      max_break_minutes: 0, yearly_vacation_days: 0, weekly_school_days: 0,
      allows_monthly_plan: false, position_order: 50,
      description: 'Freelancer ohne festes Arbeitspensum. Keine Tages-/Wochensollwerte, keine Urlaubstage.'
    }
  ].freeze

  def self.seed_legal_defaults!
    LEGAL_DEFAULTS.each do |attrs|
      rec = find_or_initialize_by(slug: attrs[:slug])
      next if rec.persisted?
      rec.assign_attributes(attrs)
      rec.save!
    end
  end

  def variable_hours?
    allows_monthly_plan?
  end

  def freelancer?
    slug == 'freelancer'
  end

  def auszubildender?
    slug == 'auszubildender'
  end

  # Whether the role mandates a fixed daily/weekly target. Variable-hours
  # roles (Werkstudent/Praktikant via monthly plans) and freelancers do not.
  def fixed_pensum?
    !allows_monthly_plan? && !freelancer? &&
      (weekly_target_minutes.to_i.positive? || daily_target_minutes.to_i.positive?)
  end

  # Whether the role normally has Berufsschule days (Azubi).
  def supports_school_days?
    weekly_school_days.to_i.positive?
  end

  def supports_vacation?
    yearly_vacation_days.to_i.positive? && !freelancer?
  end
end
