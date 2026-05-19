class CreateHmLecturePeriods < ActiveRecord::Migration[6.1]
  def change
    create_table :hm_lecture_periods do |t|
      t.integer :user_id,                null: false
      # 'lecture' = Vorlesungszeit (eingeschränktes Pensum)
      # 'break'   = vorlesungsfreie Zeit (volles Pensum)
      t.string  :kind,                   null: false, limit: 16
      t.date    :starts_on,              null: false
      t.date    :ends_on,                null: false
      t.integer :weekly_target_minutes
      t.integer :daily_target_minutes
      t.string  :label,                  limit: 80
      t.text    :notes
      t.timestamps null: false
    end
    add_index :hm_lecture_periods, :user_id
    add_index :hm_lecture_periods, [:user_id, :starts_on, :ends_on], name: 'idx_hm_lec_user_range'
  end
end
