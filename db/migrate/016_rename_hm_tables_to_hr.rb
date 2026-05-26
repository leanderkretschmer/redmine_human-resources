class RenameHmTablesToHr < ActiveRecord::Migration[7.0]
  RENAMES = {
    'hm_work_entries'     => 'hr_work_entries',
    'hm_break_entries'    => 'hr_break_entries',
    'hm_user_settings'    => 'hr_user_settings',
    'hm_absences'         => 'hr_absences',
    'hm_absence_audits'   => 'hr_absence_audits',
    'hm_employment_types' => 'hr_employment_types',
    'hm_monthly_plans'    => 'hr_monthly_plans',
    'hm_lecture_periods'  => 'hr_lecture_periods',
    'hm_holiday_caches'   => 'hr_holiday_caches'
  }.freeze

  def up
    RENAMES.each do |old_name, new_name|
      if table_exists?(old_name) && !table_exists?(new_name)
        rename_table old_name, new_name
      end
    end
  end

  def down
    RENAMES.each do |old_name, new_name|
      if table_exists?(new_name) && !table_exists?(old_name)
        rename_table new_name, old_name
      end
    end
  end
end
