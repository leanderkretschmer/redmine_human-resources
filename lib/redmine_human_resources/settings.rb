module RedmineHumanResources
  module Settings
    module_function

    def all
      Setting.plugin_redmine_human_resources || {}
    end

    # :monday (default) or :sunday — matches Rails' beginning_of_week argument.
    def first_day_of_week
      all['first_day_of_week'].to_s.downcase == 'sunday' ? :sunday : :monday
    end

    # ActiveSupport::TimeZone object, falling back to Time.zone when the
    # configured name is missing or invalid.
    def default_time_zone
      tz_name = all['default_time_zone'].to_s
      ActiveSupport::TimeZone[tz_name] || Time.zone
    end

    # Effective time zone for `user` — their own Redmine setting first, then
    # the plugin default.
    def user_time_zone(user)
      (user.respond_to?(:time_zone) && user.time_zone) || default_time_zone
    end
  end
end
