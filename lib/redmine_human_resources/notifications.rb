module RedmineHumanResources
  module Notifications
    module_function

    def recipients
      raw = (Setting.plugin_redmine_human_resources || {})['notification_emails'].to_s
      raw.split(/[,;\s]+/).map(&:strip).reject(&:blank?).uniq
    end

    def conflict_padding_days
      raw = (Setting.plugin_redmine_human_resources || {})['conflict_padding_days'].to_i
      raw.positive? ? raw : 7
    end

    def deliver_message(message)
      return unless message
      if message.respond_to?(:deliver_later)
        message.deliver_later
      else
        message.deliver_now
      end
    rescue StandardError => e
      Rails.logger.warn("[hr] mail delivery failed: #{e.class}: #{e.message}") if defined?(Rails)
      nil
    end
  end
end
