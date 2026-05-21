module HmTimeclockHelper
  def hm_format_seconds(seconds)
    seconds = seconds.to_i
    seconds = 0 if seconds.negative?
    h = seconds / 3600
    m = (seconds % 3600) / 60
    format('%02d:%02d', h, m)
  end

  def hm_format_seconds_with_seconds(seconds)
    seconds = seconds.to_i
    seconds = 0 if seconds.negative?
    h = seconds / 3600
    m = (seconds % 3600) / 60
    s = seconds % 60
    format('%02d:%02d:%02d', h, m, s)
  end

  def hm_state_label(state)
    case state.to_s
    when 'working', HmWorkEntry::STATE_RUNNING
      l(:label_hm_timeclock_state_working)
    when 'on_break', HmWorkEntry::STATE_PAUSED
      l(:label_hm_timeclock_state_on_break)
    else
      l(:label_hm_timeclock_state_idle)
    end
  end

  def hm_truthy?(value)
    ['1', 1, true, 'true'].include?(value)
  end

  # Formats a possibly-fractional day count, e.g. 4.5 → "4,5" (de) / "4.5" (en),
  # 4.0 → "4". Half days are the only fractions we produce.
  def hm_format_days(value)
    v = value.to_f
    str = (v % 1).zero? ? v.to_i.to_s : format('%.1f', v)
    str = str.tr('.', I18n.t('number.format.separator', default: '.'))
    str
  end

  def hm_calendar_cells(month)
    start_pad = (month.cwday - 1)
    cells = Array.new(start_pad)
    (month..month.end_of_month).each { |d| cells << d }
    cells << nil while cells.size % 7 != 0
    cells
  end

  def hm_totals_by_day(entries, time_zone)
    tz = time_zone || Time.zone
    entries.group_by { |e| e.started_at.in_time_zone(tz).to_date }
           .transform_values { |list| list.sum { |e| e.net_seconds } }
  end
end
