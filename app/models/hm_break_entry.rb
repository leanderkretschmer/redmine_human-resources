class HmBreakEntry < ActiveRecord::Base
  self.table_name = 'hr_break_entries'

  belongs_to :hm_work_entry

  validates :started_at, presence: true

  def open?
    ended_at.nil?
  end

  def duration_seconds(as_of: Time.current)
    finish = ended_at || as_of
    diff = (finish - started_at).to_i
    diff.positive? ? diff : 0
  end
end
