class HmQuickController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false
  skip_before_action :check_if_login_required, raise: false

  ACTIONS = %w[start stop toggle].freeze

  def perform
    action = params[:do].to_s
    unless ACTIONS.include?(action)
      return render_result(:error, l(:hm_quick_unknown_action), status: 400)
    end

    key = params[:key].to_s.strip
    if key.blank?
      return render_result(:error, l(:hm_quick_missing_key), status: 401)
    end

    user = User.find_by_api_key(key) rescue nil
    if user.nil? || !user.active?
      return render_result(:error, l(:hm_quick_invalid_key), status: 401)
    end

    User.current = user
    @user = user

    open_entry = HmWorkEntry.for_user(user).open.order(started_at: :desc).first
    overdue    = open_entry && open_entry.overdue?(as_of: Time.current)

    if overdue
      return render_result(:warning, l(:hm_quick_needs_correction),
                           details: l(:hm_quick_needs_correction_hint))
    end

    case action
    when 'start'  then do_start(open_entry)
    when 'stop'   then do_stop(open_entry)
    when 'toggle' then open_entry ? do_stop(open_entry) : do_start(nil)
    end
  end

  private

  def do_start(open_entry)
    if open_entry
      since = format_local(open_entry.started_at)
      return render_result(:info, l(:hm_quick_already_running),
                           details: l(:hm_quick_already_running_since, since: since))
    end

    HmWorkEntry.create!(
      user_id:    @user.id,
      started_at: Time.current,
      state:      HmWorkEntry::STATE_RUNNING,
      created_ip: request.remote_ip,
      notes:      'via NFC'
    )
    render_result(:success, l(:hm_quick_started_title),
                  details: l(:hm_quick_started_at, time: format_local(Time.current)))
  end

  def do_stop(open_entry)
    unless open_entry
      return render_result(:info, l(:hm_quick_not_running),
                           details: l(:hm_quick_not_running_hint))
    end

    HmWorkEntry.transaction do
      brk = open_entry.current_break
      brk&.update!(ended_at: Time.current)
      open_entry.update!(state: HmWorkEntry::STATE_COMPLETED, ended_at: Time.current)
    end

    net = open_entry.reload.net_seconds
    render_result(:success, l(:hm_quick_stopped_title),
                  details: l(:hm_quick_stopped_at_with_total,
                             time: format_local(Time.current),
                             total: hm_quick_format_hm(net)))
  end

  def render_result(status, title, details: nil, status_code: nil)
    @status = status
    @title  = title
    @details = details
    @snapshot = build_snapshot
    code = status_code || (status == :error ? 400 : 200)
    render :result, layout: 'hm_quick', status: code
  end

  def build_snapshot
    setting = HmUserSetting.for(@user)
    RedmineHumanResources::Snapshot.new(@user, setting).to_h
  rescue StandardError
    nil
  end

  def format_local(time)
    tz = (@user && @user.time_zone) || Time.zone
    time.in_time_zone(tz).strftime('%H:%M')
  end

  helper_method :hm_quick_format_hm
  def hm_quick_format_hm(seconds)
    s = seconds.to_i
    s = 0 if s.negative?
    h = s / 3600
    m = (s % 3600) / 60
    format('%dh %02dmin', h, m)
  end
end
