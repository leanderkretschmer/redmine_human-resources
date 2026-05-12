class AddSchoolWeekdays < ActiveRecord::Migration[7.0]
  def change
    add_column :hm_user_settings,    :school_weekdays_override, :string, limit: 32
    add_column :hm_employment_types, :school_weekdays_pattern,  :string, limit: 32
  end
end
