class AddFullSchoolWeekdayOverride < ActiveRecord::Migration[7.0]
  TABLE  = :hr_user_settings
  COLUMN = :full_school_weekday_override

  def up
    return unless table_exists?(TABLE)
    return if column_exists?(TABLE, COLUMN)
    add_column TABLE, COLUMN, :integer, limit: 1, null: true
  end

  def down
    return unless table_exists?(TABLE)
    return unless column_exists?(TABLE, COLUMN)
    remove_column TABLE, COLUMN
  end
end
