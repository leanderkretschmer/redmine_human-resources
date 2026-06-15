RedmineApp::Application.routes.draw do
  scope 'hr_timeclock' do
    get   '',         to: 'hr_timeclock#show',            as: 'hr_timeclock'
    get   'status',   to: 'hr_timeclock#status',          as: 'hr_timeclock_status'
    get   'calendar', to: 'hr_timeclock#calendar',        as: 'hr_timeclock_calendar'
    get   'settings', to: 'hr_timeclock#edit_settings',   as: 'edit_hr_timeclock_settings'
    match 'settings', to: 'hr_timeclock#update_settings', via: [:patch, :put, :post]
    post  'start',    to: 'hr_timeclock#start',           as: 'start_hr_timeclock'
    post  'pause',    to: 'hr_timeclock#pause',           as: 'pause_hr_timeclock'
    post  'resume',   to: 'hr_timeclock#resume',          as: 'resume_hr_timeclock'
    post  'stop',     to: 'hr_timeclock#stop',            as: 'stop_hr_timeclock'
    post  'correct/:id', to: 'hr_timeclock#correct',      as: 'correct_hr_timeclock'
    get   'export',   to: 'hr_timeclock#export',          as: 'export_hr_timeclock'
    get   'day/:date', to: 'hr_timeclock#day_detail',     as: 'day_hr_timeclock',
          constraints: { date: /\d{4}-\d{2}-\d{2}/ }
    get   'quick/:do', to: 'hr_quick#perform',            as: 'hr_quick',
          constraints: { do: /start|stop|toggle/ }
  end

  get  'hr_vacation',   to: 'hr_vacation#show',   as: 'hr_vacation'
  post 'hr_vacation',   to: 'hr_vacation#create'
  get  'hr_sickness',   to: 'hr_sickness#show',   as: 'hr_sickness'
  post 'hr_sickness',   to: 'hr_sickness#create'
  get  'hr_homeoffice', to: 'hr_homeoffice#show', as: 'hr_homeoffice'
  post 'hr_homeoffice', to: 'hr_homeoffice#create'
  get  'hr_care',       to: 'hr_care#show',       as: 'hr_care'
  post 'hr_care',       to: 'hr_care#create'
  get  'hr_planning',   to: 'hr_planning#show',   as: 'hr_planning'

  post   'hr_absences',              to: 'hr_absences#create',  as: 'hr_absences'
  get    'hr_absences/:id/edit',     to: 'hr_absences#edit',    as: 'edit_hr_absence'
  patch  'hr_absences/:id',          to: 'hr_absences#update',  as: 'hr_absence'
  put    'hr_absences/:id',          to: 'hr_absences#update'
  delete 'hr_absences/:id',          to: 'hr_absences#destroy'
  post   'hr_absences/:id/approve',  to: 'hr_absences#approve', as: 'approve_hr_absence'
  post   'hr_absences/:id/reject',   to: 'hr_absences#reject',  as: 'reject_hr_absence'

  scope 'admin/hr_timeclock' do
    get 'day/:date',       to: 'hr_admin#day',   as: 'hr_admin_day',
        constraints: { date: /\d{4}-\d{2}-\d{2}/ }

    get  'import',          to: 'hr_admin_imports#new',      as: 'hr_admin_import'
    get  'import/template', to: 'hr_admin_imports#template', as: 'hr_admin_import_template'
    post 'import/preview',  to: 'hr_admin_imports#preview',  as: 'hr_admin_import_preview'
    post 'import/commit',   to: 'hr_admin_imports#commit',   as: 'hr_admin_import_commit'

    get 'users/:user_id',  to: 'hr_admin#show',  as: 'hr_admin_user'
    get '',                to: 'hr_admin#index', as: 'hr_admin'

    get  'employment_types',          to: 'hr_admin_employment_types#index',   as: 'hr_admin_employment_types'
    get  'employment_types/new',      to: 'hr_admin_employment_types#new',     as: 'new_hr_admin_employment_type'
    post 'employment_types',          to: 'hr_admin_employment_types#create'
    get  'employment_types/:id/edit', to: 'hr_admin_employment_types#edit',    as: 'edit_hr_admin_employment_type'
    patch 'employment_types/:id',     to: 'hr_admin_employment_types#update',  as: 'hr_admin_employment_type'
    put  'employment_types/:id',      to: 'hr_admin_employment_types#update'
    delete 'employment_types/:id',    to: 'hr_admin_employment_types#destroy'

    patch 'users/:user_id/setting',   to: 'hr_admin_user_settings#update',     as: 'update_hr_admin_user_setting'
    post  'users/:user_id/plans',     to: 'hr_admin_monthly_plans#create',     as: 'hr_admin_user_monthly_plans'
    patch 'users/:user_id/plans/:id', to: 'hr_admin_monthly_plans#update',     as: 'hr_admin_user_monthly_plan'
    delete 'users/:user_id/plans/:id', to: 'hr_admin_monthly_plans#destroy'

    post   'users/:user_id/lecture_periods',     to: 'hr_admin_lecture_periods#create',  as: 'hr_admin_user_lecture_periods'
    patch  'users/:user_id/lecture_periods/:id', to: 'hr_admin_lecture_periods#update',  as: 'hr_admin_user_lecture_period'
    delete 'users/:user_id/lecture_periods/:id', to: 'hr_admin_lecture_periods#destroy'
  end
end
