class HrLecturePeriod < ActiveRecord::Base
  self.table_name = 'hr_lecture_periods'

  KIND_LECTURE = 'lecture'.freeze
  KIND_BREAK   = 'break'.freeze
  KINDS = [KIND_LECTURE, KIND_BREAK].freeze

  belongs_to :user

  validates :user_id,   presence: true
  validates :kind,      presence: true, inclusion: { in: KINDS }
  validates :starts_on, presence: true
  validates :ends_on,   presence: true
  validate  :ends_after_starts
  validate  :no_overlap

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :covering, ->(date) { where('starts_on <= :d AND ends_on >= :d', d: date) }
  scope :ordered,  -> { order(:starts_on) }

  def self.label_for(kind)
    case kind
    when KIND_LECTURE then I18n.t(:label_hr_lecture_kind_lecture)
    when KIND_BREAK   then I18n.t(:label_hr_lecture_kind_break)
    else kind.to_s
    end
  end

  def lecture?
    kind == KIND_LECTURE
  end

  def break?
    kind == KIND_BREAK
  end

  def effective_label
    label.presence || self.class.label_for(kind)
  end

  # Daily minutes a Werksstudent should hit on `date` if this period applies.
  # If daily_target_minutes is set, use it directly.
  # Otherwise distribute weekly_target_minutes across Mon-Fri.
  def daily_minutes_for(date)
    return 0 unless covers?(date)
    return daily_target_minutes.to_i if daily_target_minutes.to_i.positive?
    return 0 if weekly_target_minutes.to_i <= 0
    return 0 if date.cwday > 5
    (weekly_target_minutes.to_f / 5.0).round
  end

  def covers?(date)
    date && starts_on && ends_on && starts_on <= date && ends_on >= date
  end

  private

  def ends_after_starts
    return unless starts_on && ends_on
    errors.add(:ends_on, :must_be_on_or_after_start) if ends_on < starts_on
  end

  def no_overlap
    return unless user_id && starts_on && ends_on
    rel = self.class.where(user_id: user_id)
                    .where('starts_on <= ? AND ends_on >= ?', ends_on, starts_on)
    rel = rel.where.not(id: id) if persisted?
    errors.add(:base, :hr_lecture_period_overlap) if rel.exists?
  end
end
