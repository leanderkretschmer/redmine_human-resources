class HmEmploymentType < ActiveRecord::Base
  self.table_name = 'hm_employment_types'

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
      slug: 'fulltime_40_school_1',
      name: 'Vollzeit 40h + 1 Berufsschultag',
      weekly_target_minutes: 2400, daily_target_minutes: 480,
      max_break_minutes: 30, yearly_vacation_days: 20, weekly_school_days: 1,
      allows_monthly_plan: false, position_order: 11,
      description: '40h-Stelle mit einem wöchentlichen Berufsschultag.'
    },
    {
      slug: 'fulltime_40_school_2',
      name: 'Vollzeit 40h + 2 Berufsschultage',
      weekly_target_minutes: 2400, daily_target_minutes: 480,
      max_break_minutes: 30, yearly_vacation_days: 20, weekly_school_days: 2,
      allows_monthly_plan: false, position_order: 12,
      description: '40h-Stelle mit zwei wöchentlichen Berufsschultagen.'
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
end
