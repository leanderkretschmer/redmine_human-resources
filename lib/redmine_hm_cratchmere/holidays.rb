module RedmineHmCratchmere
  module Holidays
    module_function

    def easter_date(year)
      a       = year % 19
      b, c    = year.divmod(100)
      d, e    = b.divmod(4)
      f       = (b + 8) / 25
      g       = (b - f + 1) / 3
      h       = (19 * a + b - d - g + 15) % 30
      i, k    = c.divmod(4)
      l       = (32 + 2 * e + 2 * i - h - k) % 7
      m       = (a + 11 * h + 22 * l) / 451
      month   = (h + l - 7 * m + 114) / 31
      day     = ((h + l - 7 * m + 114) % 31) + 1
      Date.new(year, month, day)
    end

    # Federal German holidays (Bundesweit). State-specific ones omitted on purpose
    # so we only count what every employee in DE shares.
    def holidays_for(year)
      easter = easter_date(year)
      {
        Date.new(year, 1, 1)   => 'Neujahr',
        easter - 2             => 'Karfreitag',
        easter + 1             => 'Ostermontag',
        Date.new(year, 5, 1)   => 'Tag der Arbeit',
        easter + 39            => 'Christi Himmelfahrt',
        easter + 50            => 'Pfingstmontag',
        Date.new(year, 10, 3)  => 'Tag der Deutschen Einheit',
        Date.new(year, 12, 25) => '1. Weihnachtstag',
        Date.new(year, 12, 26) => '2. Weihnachtstag'
      }
    end

    def holiday?(date)
      holidays_for(date.year).key?(date)
    end

    def holiday_name(date)
      holidays_for(date.year)[date]
    end

    def weekend?(date)
      date.cwday == 6 || date.cwday == 7
    end

    def working_day?(date)
      !weekend?(date) && !holiday?(date)
    end

    def breakdown(starts_on, ends_on)
      working = 0
      weekend = 0
      holidays_hit = []
      (starts_on..ends_on).each do |d|
        if weekend?(d)
          weekend += 1
        elsif holiday?(d)
          holidays_hit << { date: d, name: holiday_name(d) }
        else
          working += 1
        end
      end
      {
        total:    (ends_on - starts_on).to_i + 1,
        working:  working,
        weekend:  weekend,
        holidays: holidays_hit
      }
    end
  end
end
