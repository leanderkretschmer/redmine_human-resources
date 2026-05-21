require 'net/http'
require 'json'
require 'uri'

module RedmineHmCratchmere
  # Thin client for the OpenHolidays API (https://openholidaysapi.org).
  # Public, no API key. We only request *public* holidays for a German
  # subdivision (e.g. "DE-BW") and one calendar year at a time.
  module OpenHolidays
    BASE_URL    = 'https://openholidaysapi.org/PublicHolidays'.freeze
    COUNTRY     = 'DE'.freeze
    HTTP_TIMEOUT = 6 # seconds

    # German federal states → OpenHolidays subdivision codes.
    GERMAN_STATES = {
      'DE-BW' => 'Baden-Württemberg',
      'DE-BY' => 'Bayern',
      'DE-BE' => 'Berlin',
      'DE-BB' => 'Brandenburg',
      'DE-HB' => 'Bremen',
      'DE-HH' => 'Hamburg',
      'DE-HE' => 'Hessen',
      'DE-MV' => 'Mecklenburg-Vorpommern',
      'DE-NI' => 'Niedersachsen',
      'DE-NW' => 'Nordrhein-Westfalen',
      'DE-RP' => 'Rheinland-Pfalz',
      'DE-SL' => 'Saarland',
      'DE-SN' => 'Sachsen',
      'DE-ST' => 'Sachsen-Anhalt',
      'DE-SH' => 'Schleswig-Holstein',
      'DE-TH' => 'Thüringen'
    }.freeze

    module_function

    def known_region?(region_code)
      GERMAN_STATES.key?(region_code)
    end

    def region_name(region_code)
      GERMAN_STATES[region_code]
    end

    # Returns { Date => name } for the given subdivision and year, or nil on error.
    def fetch(region_code, year)
      return nil unless known_region?(region_code)
      from = "#{year}-01-01"
      to   = "#{year}-12-31"
      uri = URI(BASE_URL)
      uri.query = URI.encode_www_form(
        countryIsoCode:     COUNTRY,
        subdivisionCode:    region_code,
        languageIsoCode:    'DE',
        validFrom:          from,
        validTo:            to
      )

      body = http_get(uri)
      return nil unless body

      data = JSON.parse(body)
      return nil unless data.is_a?(Array)

      data.each_with_object({}) do |entry, h|
        date = Date.parse(entry['startDate']) rescue nil
        next unless date
        name = pick_name(entry['name']) || 'Feiertag'
        h[date] = name
      end
    rescue StandardError => e
      Rails.logger.warn("[hm_cratchmere] OpenHolidays fetch failed (#{region_code}/#{year}): #{e.message}") if defined?(Rails)
      nil
    end

    def http_get(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT
      req = Net::HTTP::Get.new(uri)
      req['Accept'] = 'application/json'
      res = http.request(req)
      return res.body if res.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("[hm_cratchmere] OpenHolidays HTTP #{res.code}") if defined?(Rails)
      nil
    rescue StandardError => e
      Rails.logger.warn("[hm_cratchmere] OpenHolidays HTTP error: #{e.message}") if defined?(Rails)
      nil
    end

    # OpenHolidays returns name as [{ "language" => "DE", "text" => "..." }, ...]
    def pick_name(name_field)
      return name_field if name_field.is_a?(String)
      return nil unless name_field.is_a?(Array)
      de = name_field.find { |n| n['language'].to_s.upcase == 'DE' }
      (de || name_field.first)&.fetch('text', nil)
    end
  end
end
