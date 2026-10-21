class CreateHrFreeEntries < ActiveRecord::Migration[7.0]
  TABLE = :hr_free_entries

  def up
    return if table_exists?(TABLE)
    create_table TABLE do |t|
      t.integer  :user_id,          null: false
      t.integer  :hr_work_entry_id, null: true
      t.date     :spent_on,         null: false
      t.integer  :seconds,          null: false, default: 0
      t.string   :note,             null: false, limit: 500
      t.timestamps
    end
    add_index TABLE, :user_id
    add_index TABLE, :spent_on
    add_index TABLE, :hr_work_entry_id
  end

  def down
    return unless table_exists?(TABLE)
    drop_table TABLE
  end
end
