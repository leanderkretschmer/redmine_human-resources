class MigratePluginSettingsToHumanResources < ActiveRecord::Migration[6.1]
  # The plugin was renamed from :redmine_hm_cratchmere to :redmine_human_resources.
  # Redmine stores plugin settings under "plugin_<symbol>" in the settings table,
  # so the existing configuration would otherwise be orphaned. Copy it to the new
  # key on first migration (idempotent: only acts if the new key isn't set yet).
  def up
    old_name = 'plugin_redmine_hm_cratchmere'
    new_name = 'plugin_redmine_human_resources'
    old_row = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.send(:sanitize_sql, ["SELECT value FROM settings WHERE name = ? LIMIT 1", old_name])
    ).first
    return unless old_row && old_row['value'].present?

    new_row = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.send(:sanitize_sql, ["SELECT id FROM settings WHERE name = ? LIMIT 1", new_name])
    ).first
    return if new_row # new key already exists — leave it alone

    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.send(:sanitize_sql_array, [
        "INSERT INTO settings (name, value, updated_on) VALUES (?, ?, ?)",
        new_name, old_row['value'], Time.now.utc.strftime('%Y-%m-%d %H:%M:%S')
      ])
    )
  end

  def down
    # one-time rename — nothing to revert
  end
end
