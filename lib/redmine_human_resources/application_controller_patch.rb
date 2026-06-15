module RedmineHumanResources
  module ApplicationControllerPatch
    def self.prepended(base)
      base.before_action :hr_track_last_seen
    end

    private

    def hr_track_last_seen
      RedmineHumanResources::Tracker.touch(User.current) if User.current&.logged?
    end
  end
end
