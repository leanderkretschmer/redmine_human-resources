class MergeAzubiAndAddFreelancer < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:hr_employment_types)

    school1 = select_one("SELECT id FROM hr_employment_types WHERE slug = 'fulltime_40_school_1'")
    school2 = select_one("SELECT id FROM hr_employment_types WHERE slug = 'fulltime_40_school_2'")
    merged  = select_one("SELECT id FROM hr_employment_types WHERE slug = 'auszubildender'")

    canonical_id = merged && merged['id']

    if school1 && canonical_id.nil?
      execute <<~SQL
        UPDATE hr_employment_types
           SET slug                = 'auszubildender',
               name                = 'Auszubildender',
               weekly_target_minutes = 1920,
               daily_target_minutes  = 480,
               weekly_school_days    = 1,
               school_weekdays_pattern = '',
               description         = 'Ausbildungsstelle. Berufsschultage und Wochenstunden werden je Person eingestellt.'
         WHERE id = #{school1['id'].to_i}
      SQL
      canonical_id = school1['id'].to_i
    end

    if school2 && canonical_id
      execute <<~SQL
        UPDATE hr_user_settings
           SET hm_employment_type_id   = #{canonical_id.to_i},
               weekly_school_days_override = COALESCE(weekly_school_days_override, 2),
               weekly_target_minutes   = COALESCE(weekly_target_minutes, 1680)
         WHERE hm_employment_type_id = #{school2['id'].to_i}
      SQL
      execute "DELETE FROM hr_employment_types WHERE id = #{school2['id'].to_i}"
    end

    has_freelancer = select_one("SELECT id FROM hr_employment_types WHERE slug = 'freelancer'")
    return if has_freelancer

    execute <<~SQL
      INSERT INTO hr_employment_types
        (slug, name,
         weekly_target_minutes, daily_target_minutes,
         max_break_minutes, yearly_vacation_days, weekly_school_days,
         allows_monthly_plan, position_order, description, archived,
         created_at, updated_at)
      VALUES
        ('freelancer', 'Freelancer',
         NULL, NULL,
         0, 0, 0,
         #{quote_bool(false)}, 50,
         'Freelancer ohne festes Arbeitspensum. Keine Tages-/Wochensollwerte, keine Urlaubstage.',
         #{quote_bool(false)},
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def down
    # One-way: rebuilding the previous Azubi split would require guessing each
    # user's original assignment, which the merge step intentionally hid.
  end

  private

  def quote_bool(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
