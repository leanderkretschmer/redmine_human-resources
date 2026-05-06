module RedmineHmCratchmere
  class Snapshot
    def initialize(user, user_setting = nil, now: Time.current)
      @user    = user
      @setting = user_setting || HmUserSetting.for(user)
      @tz      = user.time_zone || Time.zone
      @now     = now
    end

    def to_h
      settings = Setting.plugin_redmine_hm_cratchmere || {}
      daily_target_seconds = @setting.effective_daily_target_minutes.to_i * 60
      max_break_seconds    = @setting.effective_max_break_minutes.to_i * 60
      overtime_threshold   = (positive_int(settings['overtime_threshold_minutes']) || 480) * 60
      poll_interval        = positive_int(settings['poll_interval_seconds']) || 30

      open_entry = HmWorkEntry.for_user(@user).open.order(started_at: :desc).first
      if open_entry &&
         !open_entry.overdue?(as_of: @now) &&
         open_entry.auto_close_overlong_break!(max_break_seconds, as_of: @now)
        open_entry = HmWorkEntry.for_user(@user).open.order(started_at: :desc).first
      end

      overdue          = open_entry && open_entry.overdue?(as_of: @now)
      todays_completed = HmWorkEntry.for_user(@user).completed.on_day(@tz, today_date).to_a
      worked_completed  = todays_completed.sum { |e| e.net_seconds(as_of: @now) }
      break_total_today = todays_completed.sum { |e| e.total_break_seconds(as_of: @now) }

      worked_open               = 0
      current_break_started_at  = nil
      current_break_seconds     = 0
      state                     = 'idle'

      if open_entry && !overdue
        worked_open = open_entry.net_seconds(as_of: @now)
        break_total_today += open_entry.total_break_seconds(as_of: @now)
        current_break_started_at = open_entry.current_break&.started_at
        current_break_seconds    = current_break_started_at ? (@now - current_break_started_at).to_i : 0
        state = open_entry.paused? ? 'on_break' : 'working'
      elsif overdue
        state = 'needs_correction'
      end

      worked_total = worked_completed + worked_open

      first_today =
        ([open_entry, *todays_completed].compact - (overdue ? [open_entry] : [])).min_by(&:started_at)
      expected_end_unix = nil
      if first_today && (state == 'working' || state == 'on_break') && daily_target_seconds.positive?
        expected_end_unix = (first_today.started_at + (daily_target_seconds + break_total_today).seconds).to_i
      end

      pending_correction = overdue ? build_correction_payload(open_entry) : nil

      {
        state: state,
        as_of_unix: @now.to_i,
        work_started_at_unix: ((state == 'working' || state == 'on_break') ? open_entry&.started_at&.to_i : nil),
        current_break_started_at_unix: current_break_started_at&.to_i,
        worked_seconds_today: worked_total,
        current_break_seconds: current_break_seconds,
        total_break_seconds_today: break_total_today,
        daily_target_seconds: daily_target_seconds,
        max_break_seconds: max_break_seconds,
        overtime_threshold_seconds: overtime_threshold,
        expected_end_unix: expected_end_unix,
        first_today_started_at_unix: first_today&.started_at&.to_i,
        pending_correction: pending_correction,
        notify_target_reached: !!@setting.notify_target_reached && truthy?(settings['enable_target_notifications']),
        notify_break_over:     !!@setting.notify_break_over     && truthy?(settings['enable_break_notifications']),
        poll_interval_seconds: poll_interval,
        labels: {
          target_reached:   I18n.t(:hm_timeclock_notify_target_reached),
          break_over:       I18n.t(:hm_timeclock_notify_break_over),
          needs_correction: I18n.t(:label_hm_timeclock_needs_correction),
          target_done:      I18n.t(:label_hm_timeclock_target_done)
        }
      }
    end

    private

    def build_correction_payload(entry)
      started_day_end = entry.started_at.in_time_zone(@tz).end_of_day
      last_seen       = @setting.last_seen_at
      suggested =
        if last_seen && last_seen > entry.started_at && last_seen <= started_day_end
          last_seen
        elsif last_seen && last_seen > started_day_end
          started_day_end
        else
          started_day_end
        end
      {
        id: entry.id,
        started_at_unix:     entry.started_at.to_i,
        started_at_label:    fmt_dt(entry.started_at),
        started_on_label:    fmt_d(entry.started_at),
        last_seen_at_unix:   last_seen&.to_i,
        last_seen_at_label:  last_seen ? fmt_dt(last_seen) : nil,
        suggested_end_unix:  suggested.to_i,
        suggested_end_label: fmt_dt(suggested),
        day_end_unix:        started_day_end.to_i,
        day_end_label:       fmt_dt(started_day_end)
      }
    end

    def fmt_dt(t)
      I18n.l(t.in_time_zone(@tz), format: :default)
    rescue StandardError
      t.in_time_zone(@tz).strftime('%Y-%m-%d %H:%M')
    end

    def fmt_d(t)
      I18n.l(t.in_time_zone(@tz).to_date, format: :default)
    rescue StandardError
      t.in_time_zone(@tz).strftime('%Y-%m-%d')
    end

    def today_date
      Time.use_zone(@tz) { Time.zone.today }
    end

    def truthy?(v)
      ['1', 1, true, 'true'].include?(v)
    end

    def positive_int(v)
      i = v.to_i
      i.positive? ? i : nil
    end
  end
end
