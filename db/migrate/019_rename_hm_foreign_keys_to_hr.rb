class RenameHmForeignKeysToHr < ActiveRecord::Migration[7.0]
  COLUMN_RENAMES = {
    'hr_user_settings'  => { 'hm_employment_type_id' => 'hr_employment_type_id' },
    'hr_break_entries'  => { 'hm_work_entry_id'      => 'hr_work_entry_id' },
    'hr_absence_audits' => { 'hm_absence_id'         => 'hr_absence_id' }
  }.freeze

  INDEX_RENAMES = [
    { table: :hr_holiday_caches,
      columns: [:region_code, :year],
      old_name: 'idx_hm_holiday_cache_region_year',
      new_name: 'idx_hr_holiday_cache_region_year',
      options: { unique: true } }
  ].freeze

  def up
    COLUMN_RENAMES.each do |table, cols|
      next unless table_exists?(table.to_sym)
      cols.each do |old_col, new_col|
        next unless column_exists?(table.to_sym, old_col.to_sym)
        next if column_exists?(table.to_sym, new_col.to_sym)
        rename_column table.to_sym, old_col.to_sym, new_col.to_sym
      end
    end

    INDEX_RENAMES.each do |spec|
      next unless table_exists?(spec[:table])
      if index_exists?(spec[:table], spec[:columns], name: spec[:old_name])
        remove_index spec[:table], name: spec[:old_name]
      end
      unless index_exists?(spec[:table], spec[:columns], name: spec[:new_name])
        add_index spec[:table], spec[:columns], **spec[:options], name: spec[:new_name]
      end
    end
  end

  def down
    INDEX_RENAMES.each do |spec|
      next unless table_exists?(spec[:table])
      if index_exists?(spec[:table], spec[:columns], name: spec[:new_name])
        remove_index spec[:table], name: spec[:new_name]
      end
      unless index_exists?(spec[:table], spec[:columns], name: spec[:old_name])
        add_index spec[:table], spec[:columns], **spec[:options], name: spec[:old_name]
      end
    end

    COLUMN_RENAMES.each do |table, cols|
      next unless table_exists?(table.to_sym)
      cols.each do |old_col, new_col|
        next unless column_exists?(table.to_sym, new_col.to_sym)
        next if column_exists?(table.to_sym, old_col.to_sym)
        rename_column table.to_sym, new_col.to_sym, old_col.to_sym
      end
    end
  end
end
