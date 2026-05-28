class AddHomeofficeAndCareToHmUserSettings < ActiveRecord::Migration[7.0]
  def change
    add_column :hr_user_settings, :homeoffice_days_per_year_override, :integer
    add_column :hr_user_settings, :care_status, :string, limit: 16
    add_column :hr_user_settings, :care_hours_per_year_override, :integer
  end
end
