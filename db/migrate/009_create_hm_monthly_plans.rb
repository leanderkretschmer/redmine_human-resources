class CreateHmMonthlyPlans < ActiveRecord::Migration[7.0]
  def change
    create_table :hm_monthly_plans do |t|
      t.integer :user_id,         null: false
      t.integer :year,            null: false
      t.integer :month,           null: false
      t.integer :target_minutes,  null: false, default: 0
      t.text    :notes
      t.integer :created_by_id
      t.timestamps
    end
    add_index :hm_monthly_plans, [:user_id, :year, :month], unique: true, name: 'idx_hm_monthly_plans_user_period'
    add_index :hm_monthly_plans, [:year, :month]
  end
end
