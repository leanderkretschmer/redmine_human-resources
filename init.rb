require 'redmine'

# One-time fixup: plugin was renamed from `redmine_hm_cratchmere` to
# `redmine_human_resources` (commit 39c6557). Redmine 6 stores plugin
# migration state in `schema_migrations` with versions like
# "1-redmine_hm_cratchmere". Without this rename the new plugin id starts
# at version 0 and re-runs 001 against existing tables.
begin
  conn = ActiveRecord::Base.connection
  if conn.data_source_exists?('schema_migrations')
    old_suffix = '-redmine_hm_cratchmere'
    new_suffix = '-redmine_human_resources'
    quoted_old = conn.quote("%#{old_suffix}")
    rows = conn.select_values("SELECT version FROM schema_migrations WHERE version LIKE #{quoted_old}")
    rows.each do |old_version|
      new_version = old_version.sub(/#{Regexp.escape(old_suffix)}\z/, new_suffix)
      next if old_version == new_version
      already_present = conn.select_value("SELECT 1 FROM schema_migrations WHERE version = #{conn.quote(new_version)}")
      if already_present
        conn.execute("DELETE FROM schema_migrations WHERE version = #{conn.quote(old_version)}")
      else
        conn.execute("UPDATE schema_migrations SET version = #{conn.quote(new_version)} WHERE version = #{conn.quote(old_version)}")
      end
    end
  end
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
  # DB not ready (e.g. initial setup) — nothing to fix yet.
rescue => e
  Rails.logger.warn("[redmine_human_resources] schema_migrations rename skipped: #{e.class}: #{e.message}") if defined?(Rails) && Rails.logger
end

Rails.application.config.to_prepare do
  require_dependency File.expand_path('lib/redmine_human_resources/settings',                   __dir__)
  require_dependency File.expand_path('lib/redmine_human_resources/snapshot',                   __dir__)
  require_dependency File.expand_path('lib/redmine_human_resources/tracker',                    __dir__)
  require_dependency File.expand_path('lib/redmine_human_resources/application_controller_patch', __dir__)
  require_dependency File.expand_path('lib/redmine_human_resources/open_holidays',              __dir__)
  require_dependency File.expand_path('lib/redmine_human_resources/holidays',                   __dir__)
  require_dependency File.expand_path('lib/redmine_human_resources/notifications',              __dir__)
  require_dependency File.expand_path('lib/redmine_human_resources/hooks',                      __dir__)

  unless ApplicationController.include?(RedmineHumanResources::ApplicationControllerPatch)
    ApplicationController.prepend(RedmineHumanResources::ApplicationControllerPatch)
  end
end

Redmine::Plugin.register :redmine_human_resources do
  name 'Redmine HR Cratchmere'
  author 'Leander Kretschmer'
  description 'Personal-Modul für Redmine 6 mit Stempeluhr in der Topbar (Start/Pause/Stopp), Monatskalender, Sollarbeitszeit, Pausen- und Überstunden-Hinweisen sowie Admin-Übersicht.'
  version '0.1.0'
  url 'https://github.com/leanderkretschmer/redmine_human_resources'
  author_url 'https://github.com/leanderkretschmer'

  requires_redmine version_or_higher: '6.0.0'

  settings(
    default: {
      'default_daily_target_minutes'    => 480,
      'default_weekly_target_minutes'   => 2400,
      'default_max_break_minutes'       => 60,
      'overtime_threshold_minutes'      => 480,
      'enable_target_notifications'     => '1',
      'enable_break_notifications'      => '1',
      'poll_interval_seconds'           => 30,
      'notification_emails'             => '',
      'conflict_padding_days'           => 7,
      'long_shift_threshold_hours'      => 12,
      'enable_break_reminder'           => '0',
      'break_reminder_minutes'          => 330,
      'default_homeoffice_days_per_year' => 0,
      'default_care_hours_couple'        => 0,
      'default_care_hours_single'        => 0,
      'default_time_zone'                => 'Europe/Berlin',
      'first_day_of_week'                => 'monday'
    },
    partial: 'settings/human_resources'
  )

  menu :account_menu, :hr_timeclock,
       { controller: 'hr_timeclock', action: 'show' },
       caption: :label_hr_hr,
       before: :my_account,
       html: { id: 'hr-timeclock-menu-link', class: 'hr-timeclock-menu-link' },
       if: Proc.new { User.current.logged? }

  menu :account_menu, :hr_admin_link,
       { controller: 'hr_admin', action: 'index' },
       caption: :label_hr_admin_menu,
       after: :hr_timeclock,
       html: { id: 'hr-admin-menu-link', class: 'hr-admin-menu-link' },
       if: Proc.new { User.current.logged? && User.current.admin? }

  menu :admin_menu, :hr_admin,
       { controller: 'hr_admin', action: 'index' },
       caption: :label_hr_admin,
       html: { class: 'icon icon-time' }
end
