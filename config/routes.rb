RedmineApp::Application.routes.draw do
  scope 'hm_timeclock' do
    get   '',         to: 'hm_timeclock#show',            as: 'hm_timeclock'
    get   'status',   to: 'hm_timeclock#status',          as: 'hm_timeclock_status'
    get   'calendar', to: 'hm_timeclock#calendar',        as: 'hm_timeclock_calendar'
    get   'settings', to: 'hm_timeclock#edit_settings',   as: 'edit_hm_timeclock_settings'
    match 'settings', to: 'hm_timeclock#update_settings', via: [:patch, :put, :post]
    post  'start',    to: 'hm_timeclock#start',           as: 'start_hm_timeclock'
    post  'pause',    to: 'hm_timeclock#pause',           as: 'pause_hm_timeclock'
    post  'resume',   to: 'hm_timeclock#resume',          as: 'resume_hm_timeclock'
    post  'stop',     to: 'hm_timeclock#stop',            as: 'stop_hm_timeclock'
    post  'correct/:id', to: 'hm_timeclock#correct',      as: 'correct_hm_timeclock'
    get   'export',   to: 'hm_timeclock#export',          as: 'export_hm_timeclock'
    get   'day/:date', to: 'hm_timeclock#day_detail',     as: 'day_hm_timeclock',
          constraints: { date: /\d{4}-\d{2}-\d{2}/ }
  end

  get  'hm_vacation', to: 'hm_vacation#show',   as: 'hm_vacation'
  post 'hm_vacation', to: 'hm_vacation#create'
  get  'hm_sickness', to: 'hm_sickness#show',   as: 'hm_sickness'
  post 'hm_sickness', to: 'hm_sickness#create'

  post   'hm_absences',              to: 'hm_absences#create',  as: 'hm_absences'
  get    'hm_absences/:id/edit',     to: 'hm_absences#edit',    as: 'edit_hm_absence'
  patch  'hm_absences/:id',          to: 'hm_absences#update',  as: 'hm_absence'
  put    'hm_absences/:id',          to: 'hm_absences#update'
  delete 'hm_absences/:id',          to: 'hm_absences#destroy'
  post   'hm_absences/:id/approve',  to: 'hm_absences#approve', as: 'approve_hm_absence'
  post   'hm_absences/:id/reject',   to: 'hm_absences#reject',  as: 'reject_hm_absence'

  scope 'admin/hm_timeclock' do
    get 'day/:date',       to: 'hm_admin#day',   as: 'hm_admin_day',
        constraints: { date: /\d{4}-\d{2}-\d{2}/ }
    get 'users/:user_id',  to: 'hm_admin#show',  as: 'hm_admin_user'
    get '',                to: 'hm_admin#index', as: 'hm_admin'

    get  'employment_types',          to: 'hm_admin_employment_types#index',   as: 'hm_admin_employment_types'
    get  'employment_types/new',      to: 'hm_admin_employment_types#new',     as: 'new_hm_admin_employment_type'
    post 'employment_types',          to: 'hm_admin_employment_types#create'
    get  'employment_types/:id/edit', to: 'hm_admin_employment_types#edit',    as: 'edit_hm_admin_employment_type'
    patch 'employment_types/:id',     to: 'hm_admin_employment_types#update',  as: 'hm_admin_employment_type'
    put  'employment_types/:id',      to: 'hm_admin_employment_types#update'
    delete 'employment_types/:id',    to: 'hm_admin_employment_types#destroy'
    post 'employment_types/seed',     to: 'hm_admin_employment_types#seed',    as: 'seed_hm_admin_employment_types'

    patch 'users/:user_id/setting',   to: 'hm_admin_user_settings#update',     as: 'update_hm_admin_user_setting'
    post  'users/:user_id/plans',     to: 'hm_admin_monthly_plans#create',     as: 'hm_admin_user_monthly_plans'
    patch 'users/:user_id/plans/:id', to: 'hm_admin_monthly_plans#update',     as: 'hm_admin_user_monthly_plan'
    delete 'users/:user_id/plans/:id', to: 'hm_admin_monthly_plans#destroy'
  end
end
