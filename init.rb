require 'redmine'

# One-time fixup: plugin was renamed from `redmine_hm_cratchmere` to
# `redmine_human_resources` (commit 39c6557). Redmine keys plugin migration
# state by plugin name in `plugin_schema_info`, so without this the new name
# starts at version 0 and re-runs 001 against existing tables.
begin
  conn = ActiveRecord::Base.connection
  if conn.data_source_exists?('plugin_schema_info')
    old_name = 'redmine_hm_cratchmere'
    new_name = 'redmine_human_resources'
    quoted_old = conn.quote(old_name)
    quoted_new = conn.quote(new_name)
    has_old = conn.select_value("SELECT 1 FROM plugin_schema_info WHERE plugin_name = #{quoted_old}")
    has_new = conn.select_value("SELECT 1 FROM plugin_schema_info WHERE plugin_name = #{quoted_new}")
    if has_old && !has_new
      conn.execute("UPDATE plugin_schema_info SET plugin_name = #{quoted_new} WHERE plugin_name = #{quoted_old}")
    elsif has_old && has_new
      conn.execute("DELETE FROM plugin_schema_info WHERE plugin_name = #{quoted_old}")
    end
  end
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
  # DB not ready (e.g. initial setup) — nothing to fix yet.
rescue => e
  Rails.logger.warn("[redmine_human_resources] plugin_schema_info rename skipped: #{e.class}: #{e.message}") if defined?(Rails) && Rails.logger
end

Rails.application.config.to_prepare do
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
      'long_shift_threshold_hours'      => 12
    },
    partial: 'settings/human_resources'
  )

  menu :account_menu, :hm_timeclock,
       { controller: 'hm_timeclock', action: 'show' },
       caption: :label_hm_hr,
       before: :my_account,
       html: { id: 'hm-timeclock-menu-link', class: 'hm-timeclock-menu-link' },
       if: Proc.new { User.current.logged? }

  menu :admin_menu, :hm_admin,
       { controller: 'hm_admin', action: 'index' },
       caption: :label_hm_admin,
       html: { class: 'icon icon-time' }
end
