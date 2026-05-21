class AddRegionAndHalfDays < ActiveRecord::Migration[6.1]
  def change
    add_column :hm_user_settings, :region_code, :string, limit: 8

    add_column :hm_absences, :first_day_half, :boolean, null: false, default: false
    add_column :hm_absences, :last_day_half,  :boolean, null: false, default: false

    create_table :hm_holiday_caches do |t|
      t.string   :region_code, null: false, limit: 8
      t.integer  :year,        null: false
      t.text     :payload,     null: false # JSON: { "YYYY-MM-DD" => "Name", ... }
      t.datetime :fetched_at,  null: false
      t.timestamps null: false
    end
    add_index :hm_holiday_caches, [:region_code, :year], unique: true, name: 'idx_hm_holiday_cache_region_year'
  end
end
