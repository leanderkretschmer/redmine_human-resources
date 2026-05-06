class HmWorkEntry < ActiveRecord::Base
  self.table_name = 'hm_work_entries'

  STATE_RUNNING   = 'running'.freeze
  STATE_PAUSED    = 'paused'.freeze
  STATE_COMPLETED = 'completed'.freeze
  STATES          = [STATE_RUNNING, STATE_PAUSED, STATE_COMPLETED].freeze

  belongs_to :user
  has_many :hm_break_entries,
           -> { order(:started_at) },
           dependent: :destroy

  validates :started_at, presence: true
  validates :state, inclusion: { in: STATES }

  scope :for_user,  ->(user) { where(user_id: user.is_a?(User) ? user.id : user.to_i) }
  scope :open,      -> { where(state: [STATE_RUNNING, STATE_PAUSED]) }
  scope :completed, -> { where(state: STATE_COMPLETED) }
  scope :on_day, ->(time_zone, day) {
    tz = time_zone || Time.zone
    Time.use_zone(tz) do
      from = day.in_time_zone.beginning_of_day
      to   = day.in_time_zone.end_of_day
      where(started_at: from..to)
    end
  }
  scope :in_range, ->(from, to) { where(started_at: from..to) }

  def open?
    state != STATE_COMPLETED
  end

  def running?
    state == STATE_RUNNING
  end

  def paused?
    state == STATE_PAUSED
  end

  def current_break
    hm_break_entries.detect { |b| b.ended_at.nil? }
  end

  def user_time_zone
    user&.time_zone || Time.zone
  end

  def started_on_date
    started_at.in_time_zone(user_time_zone).to_date
  end

  def started_day_end
    started_at.in_time_zone(user_time_zone).end_of_day
  end

  def overdue?(as_of: Time.current)
    open? && started_on_date < as_of.in_time_zone(user_time_zone).to_date
  end

  def effective_end_at(as_of: Time.current)
    return ended_at if ended_at
    open? ? [as_of, started_day_end].min : started_day_end
  end

  def total_break_seconds(as_of: Time.current)
    cap = effective_end_at(as_of: as_of)
    hm_break_entries.inject(0) do |sum, b|
      finish = b.ended_at || cap
      finish = cap if finish > cap
      diff = (finish - b.started_at).to_i
      sum + (diff.positive? ? diff : 0)
    end
  end

  def gross_seconds(as_of: Time.current)
    diff = (effective_end_at(as_of: as_of) - started_at).to_i
    diff.positive? ? diff : 0
  end

  def net_seconds(as_of: Time.current)
    [gross_seconds(as_of: as_of) - total_break_seconds(as_of: as_of), 0].max
  end

  def self.to_csv(user, entries)
    require 'csv'
    CSV.generate do |csv|
      csv << %w[user_login user_name started_at ended_at gross_seconds break_seconds net_seconds state notes]
      entries.each do |e|
        csv << [user.login, user.name,
                e.started_at&.iso8601, e.ended_at&.iso8601,
                e.gross_seconds, e.total_break_seconds, e.net_seconds,
                e.state, e.notes]
      end
    end
  end

  def auto_close_overlong_break!(max_break_seconds, as_of: Time.current)
    return false unless paused?
    return false unless max_break_seconds.to_i.positive?
    brk = current_break
    return false unless brk
    elapsed = (as_of - brk.started_at).to_i
    return false if elapsed < max_break_seconds.to_i
    transaction do
      brk.update!(ended_at: brk.started_at + max_break_seconds.to_i.seconds)
      update!(state: STATE_RUNNING)
    end
    true
  end
end
