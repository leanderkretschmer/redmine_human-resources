class FixSchoolEmploymentTypes < ActiveRecord::Migration[6.1]
  def up
    return unless table_exists?(:hm_employment_types)

    execute <<~SQL
      UPDATE hm_employment_types
         SET weekly_target_minutes = 1920,
             daily_target_minutes  = 480,
             weekly_school_days    = 1,
             name = 'Ausbildung 32h + 1 Berufsschultag',
             description = 'Ausbildungsstelle: 4 Betriebs-Tage à 8h = 32h/Woche, ein Berufsschultag komplett frei (Wochentag wählbar).'
       WHERE slug = 'fulltime_40_school_1'
    SQL

    execute <<~SQL
      UPDATE hm_employment_types
         SET weekly_target_minutes = 1680,
             daily_target_minutes  = 480,
             weekly_school_days    = 2,
             name = 'Ausbildung 28h + 2 Berufsschultage',
             description = 'Ausbildungsstelle: 3 Betriebs-Tage à 8h + 1 halber Tag (4h) = 28h/Woche, zwei Berufsschultage (Wochentage wählbar).'
       WHERE slug = 'fulltime_40_school_2'
    SQL
  end

  def down
    # Keep the corrected math; nothing to revert.
  end
end
