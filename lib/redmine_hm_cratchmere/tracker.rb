module RedmineHmCratchmere
  module Tracker
    DEBOUNCE_SECONDS = 60

    def self.touch(user)
      return unless user&.logged?
      setting = HmUserSetting.find_or_initialize_by(user_id: user.id)
      now = Time.current
      if setting.new_record?
        setting.last_seen_at = now
        setting.save(validate: false)
        return
      end
      if setting.last_seen_at.nil? || (now - setting.last_seen_at) > DEBOUNCE_SECONDS
        setting.update_columns(last_seen_at: now)
      end
    rescue StandardError
      nil
    end
  end
end
