class HmHolidayCache < ActiveRecord::Base
  self.table_name = 'hr_holiday_caches'

  validates :region_code, presence: true
  validates :year, presence: true

  # Time-to-live for a cached year before we try to refresh from the API.
  TTL = 30.days

  # Returns { Date => name } for the region/year, fetching + caching from
  # OpenHolidays when needed. Returns nil if no data could be obtained.
  def self.holidays(region_code, year)
    rec = find_by(region_code: region_code, year: year)
    if rec && rec.fetched_at && rec.fetched_at > TTL.ago
      return decode(rec.payload)
    end

    fetched = ::RedmineHumanResources::OpenHolidays.fetch(region_code, year)
    if fetched
      store(region_code, year, fetched)
      return fetched
    end

    # API failed — fall back to a stale cache entry if we have one.
    rec ? decode(rec.payload) : nil
  end

  def self.store(region_code, year, hash)
    payload = JSON.generate(hash.transform_keys { |d| d.is_a?(Date) ? d.iso8601 : d.to_s })
    rec = find_or_initialize_by(region_code: region_code, year: year)
    rec.payload = payload
    rec.fetched_at = Time.current
    rec.save!
  rescue StandardError => e
    Rails.logger.warn("[hr] holiday cache store failed: #{e.message}") if defined?(Rails)
    nil
  end

  def self.decode(payload)
    JSON.parse(payload).each_with_object({}) do |(k, v), h|
      d = Date.parse(k) rescue nil
      h[d] = v if d
    end
  rescue StandardError
    {}
  end
end
