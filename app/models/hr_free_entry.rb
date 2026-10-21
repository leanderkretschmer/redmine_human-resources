class HrFreeEntry < ActiveRecord::Base
  self.table_name = 'hr_free_entries'

  belongs_to :user
  belongs_to :hr_work_entry, optional: true

  validates :user_id, :spent_on, presence: true
  validates :seconds, numericality: { greater_than: 0 }
  validates :note, presence: true, length: { maximum: 500 }

  scope :for_user, ->(user) { where(user_id: user.is_a?(User) ? user.id : user.to_i) }
  scope :on_day,   ->(day)  { where(spent_on: day) }
end
