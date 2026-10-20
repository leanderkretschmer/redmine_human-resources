module HrTimeclockHelper
  def hr_format_seconds(seconds)
    seconds = seconds.to_i
    seconds = 0 if seconds.negative?
    h = seconds / 3600
    m = (seconds % 3600) / 60
    format('%02d:%02d', h, m)
  end

  def hr_format_seconds_with_seconds(seconds)
    seconds = seconds.to_i
    seconds = 0 if seconds.negative?
    h = seconds / 3600
    m = (seconds % 3600) / 60
    s = seconds % 60
    format('%02d:%02d:%02d', h, m, s)
  end

  def hr_state_label(state)
    case state.to_s
    when 'working', HrWorkEntry::STATE_RUNNING
      l(:label_hr_timeclock_state_working)
    when 'on_break', HrWorkEntry::STATE_PAUSED
      l(:label_hr_timeclock_state_on_break)
    else
      l(:label_hr_timeclock_state_idle)
    end
  end

  def hr_truthy?(value)
    ['1', 1, true, 'true'].include?(value)
  end

  # Formats a possibly-fractional day count, e.g. 4.5 → "4,5" (de) / "4.5" (en),
  # 4.0 → "4". Half days are the only fractions we produce.
  def hr_format_days(value)
    v = value.to_f
    str = (v % 1).zero? ? v.to_i.to_s : format('%.1f', v)
    str = str.tr('.', I18n.t('number.format.separator', default: '.'))
    str
  end

  def hr_calendar_cells(month, first_day = :monday)
    first_cwday = first_day.to_sym == :sunday ? 7 : 1
    start_pad = (month.cwday - first_cwday) % 7
    cells = Array.new(start_pad)
    (month..month.end_of_month).each { |d| cells << d }
    cells << nil while cells.size % 7 != 0
    cells
  end

  # Deterministic swatch colour per user — used in the year-view admin
  # calendar to tell apart absences from different employees at a glance.
  USER_SWATCH_PALETTE = %w[#3498db #e67e22 #27ae60 #9b59b6 #1abc9c
                           #f39c12 #16a085 #d35400 #2c3e50 #8e44ad
                           #2980b9 #c0392b].freeze

  def hr_user_swatch_color(user_id)
    return '#95a5a6' unless user_id
    USER_SWATCH_PALETTE[user_id.to_i % USER_SWATCH_PALETTE.size]
  end

  def hr_totals_by_day(entries, time_zone)
    tz = time_zone || Time.zone
    entries.group_by { |e| e.started_at.in_time_zone(tz).to_date }
           .transform_values { |list| list.sum { |e| e.net_seconds } }
  end

  # Fasst aufeinanderfolgende Absences gleicher Art/Status/Reason/Partial-Fenster
  # desselben Users zu einer Gruppe zusammen (ends_on + 1 == next.starts_on).
  # Rückgabe: Array von Gruppen, jede Gruppe ist ein Hash mit :first, :last,
  # :absences, :days_total, :starts_on, :ends_on. Jede Gruppe hat mindestens
  # eine Absence; Einzel-Absences sind Gruppen der Länge 1. Reihenfolge: nach
  # starts_on absteigend (die neueste Gruppe zuerst), passend zur Standard-
  # Ordnung der Admin-Show-Liste.
  def hr_group_consecutive_absences(absences)
    sorted = absences.sort_by { |a| [a.user_id || 0, a.starts_on] }
    groups = []
    sorted.each do |abs|
      last = groups.last
      can_merge = last &&
                  last[:absences].last.user_id == abs.user_id &&
                  last[:absences].last.kind    == abs.kind &&
                  last[:absences].last.status  == abs.status &&
                  last[:absences].last.reason.to_s == abs.reason.to_s &&
                  last[:absences].last.start_time.to_s == abs.start_time.to_s &&
                  last[:absences].last.end_time.to_s   == abs.end_time.to_s &&
                  last[:ends_on] + 1 == abs.starts_on
      if can_merge
        last[:absences] << abs
        last[:ends_on]   = abs.ends_on
      else
        groups << { absences: [abs], starts_on: abs.starts_on, ends_on: abs.ends_on }
      end
    end
    groups.sort_by { |g| g[:starts_on] }.reverse
  end
end
