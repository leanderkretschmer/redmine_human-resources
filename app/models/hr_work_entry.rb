class HrWorkEntry < ActiveRecord::Base
  self.table_name = 'hr_work_entries'

  STATE_RUNNING   = 'running'.freeze
  STATE_PAUSED    = 'paused'.freeze
  STATE_COMPLETED = 'completed'.freeze
  STATES          = [STATE_RUNNING, STATE_PAUSED, STATE_COMPLETED].freeze

  CORRECTION_REQUESTED = 'requested'.freeze
  CORRECTION_STATUSES  = [CORRECTION_REQUESTED].freeze

  belongs_to :user
  has_many :hr_break_entries,
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
  scope :with_pending_correction, -> { where(correction_status: CORRECTION_REQUESTED) }

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
    hr_break_entries.detect { |b| b.ended_at.nil? }
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

  # Long-shift detection. On a trust basis the clock never stops automatically;
  # instead, once an open entry has been running longer than the configured
  # threshold we flag it so the user view can ask to confirm or correct the end.
  def self.long_shift_threshold_seconds
    settings = Setting.plugin_redmine_human_resources || {}
    hrs = settings['long_shift_threshold_hours'].to_i
    hrs = 12 unless hrs.positive?
    hrs * 3600
  end

  def overdue?(as_of: Time.current)
    return false unless open?
    (as_of - started_at).to_i >= self.class.long_shift_threshold_seconds
  end

  def effective_end_at(as_of: Time.current)
    return ended_at if ended_at
    # No midnight cap — night shifts may legitimately run past 00:00.
    as_of
  end

  def total_break_seconds(as_of: Time.current)
    cap = effective_end_at(as_of: as_of)
    hr_break_entries.inject(0) do |sum, b|
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

  # ── Self-service time corrections ────────────────────────────────────────
  # A user may propose new start/end times on their own completed entries;
  # the proposal is held in `proposed_started_at`/`proposed_ended_at` with
  # `correction_status = 'requested'` until an admin approves or rejects it.
  # The real start/end stay untouched while a correction is pending so
  # existing totals keep rendering until the admin signs off.

  def pending_correction?
    correction_status == CORRECTION_REQUESTED
  end

  def propose_correction!(new_started_at:, new_ended_at:, reason: nil)
    raise ArgumentError, 'open entries cannot be corrected' if open?
    raise ArgumentError, 'end must follow start' if new_ended_at && new_started_at && new_ended_at <= new_started_at
    update!(
      proposed_started_at: new_started_at,
      proposed_ended_at:   new_ended_at,
      correction_status:   CORRECTION_REQUESTED,
      correction_reason:   reason.to_s[0, 500],
      correction_requested_at: Time.current
    )
  end

  def approve_correction!(by_user:)
    return false unless pending_correction?
    old_start, old_end = started_at, ended_at
    new_start = proposed_started_at
    new_end   = proposed_ended_at
    reason    = correction_reason
    stamp = "[Korrektur genehmigt am #{Time.current.iso8601} durch #{by_user&.login || 'admin'}] " \
            "#{old_start&.iso8601}→#{new_start&.iso8601}, #{old_end&.iso8601}→#{new_end&.iso8601}" \
            "#{reason.present? ? " · #{reason}" : ''}"
    note = [notes.presence, stamp].compact.join("\n")
    update!(
      started_at: new_start, ended_at: new_end,
      proposed_started_at: nil, proposed_ended_at: nil,
      correction_status: nil, correction_reason: nil, correction_requested_at: nil,
      notes: note
    )
    true
  end

  def reject_correction!(by_user:, note: nil)
    return false unless pending_correction?
    stamp = "[Korrektur abgelehnt am #{Time.current.iso8601} durch #{by_user&.login || 'admin'}]" \
            "#{note.present? ? " · #{note}" : ''}"
    combined = [notes.presence, stamp].compact.join("\n")
    update!(
      proposed_started_at: nil, proposed_ended_at: nil,
      correction_status: nil, correction_reason: nil, correction_requested_at: nil,
      notes: combined
    )
    true
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
