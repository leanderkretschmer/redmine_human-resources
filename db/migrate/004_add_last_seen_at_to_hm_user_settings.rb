class AddLastSeenAtToHmUserSettings < ActiveRecord::Migration[7.0]
  def change
    add_column :hm_user_settings, :last_seen_at, :datetime
    add_index  :hm_user_settings, :last_seen_at
  end
end
