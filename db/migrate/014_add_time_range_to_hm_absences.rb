class AddTimeRangeToHmAbsences < ActiveRecord::Migration[6.1]
  def change
    add_column :hm_absences, :start_time, :string, limit: 5 # "HH:MM"
    add_column :hm_absences, :end_time,   :string, limit: 5
  end
end
