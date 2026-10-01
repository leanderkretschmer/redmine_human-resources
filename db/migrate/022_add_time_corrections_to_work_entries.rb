class AddTimeCorrectionsToWorkEntries < ActiveRecord::Migration[7.0]
  TABLE = :hr_work_entries
  COLUMNS = {
    proposed_started_at:    { type: :datetime, null: true },
    proposed_ended_at:      { type: :datetime, null: true },
    correction_status:      { type: :string,   null: true, limit: 16 },
    correction_reason:      { type: :string,   null: true, limit: 500 },
    correction_requested_at: { type: :datetime, null: true }
  }.freeze

  def up
    return unless table_exists?(TABLE)
    COLUMNS.each do |col, spec|
      next if column_exists?(TABLE, col)
      opts = spec.except(:type).merge(limit: spec[:limit]).compact
      add_column TABLE, col, spec[:type], **opts
    end
    unless index_exists?(TABLE, :correction_status)
      add_index TABLE, :correction_status
    end
  end

  def down
    return unless table_exists?(TABLE)
    if index_exists?(TABLE, :correction_status)
      remove_index TABLE, :correction_status
    end
    COLUMNS.each_key do |col|
      next unless column_exists?(TABLE, col)
      remove_column TABLE, col
    end
  end
end
