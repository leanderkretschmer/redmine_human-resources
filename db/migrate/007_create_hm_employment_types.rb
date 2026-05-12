class CreateHmEmploymentTypes < ActiveRecord::Migration[7.0]
  def change
    create_table :hm_employment_types do |t|
      t.string  :name,                            null: false, limit: 80
      t.string  :slug,                            null: false, limit: 40
      t.integer :weekly_target_minutes
      t.integer :daily_target_minutes
      t.integer :max_break_minutes,               null: false, default: 0
      t.integer :yearly_vacation_days,            null: false, default: 20
      t.integer :weekly_school_days,              null: false, default: 0
      t.boolean :allows_monthly_plan,             null: false, default: false
      t.integer :position_order,                  null: false, default: 0
      t.boolean :archived,                        null: false, default: false
      t.text    :description
      t.timestamps
    end
    add_index :hm_employment_types, :slug, unique: true
    add_index :hm_employment_types, :position_order
  end
end
