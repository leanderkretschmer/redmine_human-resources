class AddEmploymentToHmUserSettings < ActiveRecord::Migration[7.0]
  def change
    change_table :hm_user_settings do |t|
      t.references :hm_employment_type, foreign_key: true, index: true
      t.integer :yearly_vacation_days_override
      t.integer :weekly_school_days_override
      t.boolean :allows_monthly_plan_override
    end
  end
end
