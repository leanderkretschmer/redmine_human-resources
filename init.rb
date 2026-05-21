require 'redmine'

Rails.application.config.to_prepare do
  require_dependency File.expand_path('lib/redmine_hm_cratchmere/snapshot',                   __dir__)
  require_dependency File.expand_path('lib/redmine_hm_cratchmere/tracker',                    __dir__)
  require_dependency File.expand_path('lib/redmine_hm_cratchmere/application_controller_patch', __dir__)
  require_dependency File.expand_path('lib/redmine_hm_cratchmere/open_holidays',              __dir__)
  require_dependency File.expand_path('lib/redmine_hm_cratchmere/holidays',                   __dir__)
  require_dependency File.expand_path('lib/redmine_hm_cratchmere/notifications',              __dir__)
  require_dependency File.expand_path('lib/redmine_hm_cratchmere/hooks',                      __dir__)

  unless ApplicationController.include?(RedmineHmCratchmere::ApplicationControllerPatch)
    ApplicationController.prepend(RedmineHmCratchmere::ApplicationControllerPatch)
  end
end

Redmine::Plugin.register :redmine_hm_cratchmere do
  name 'Redmine HR Cratchmere'
  author 'Leander Kretschmer'
  description 'Personal-Modul für Redmine 6 mit Stempeluhr in der Topbar (Start/Pause/Stopp), Monatskalender, Sollarbeitszeit, Pausen- und Überstunden-Hinweisen sowie Admin-Übersicht.'
  version '0.1.0'
  url 'https://github.com/leanderkretschmer/redmine_hm_cratchmere'
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
    partial: 'settings/hm_cratchmere'
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
