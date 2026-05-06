module RedmineHmCratchmere
  module ApplicationControllerPatch
    def self.prepended(base)
      base.before_action :hm_track_last_seen
    end

    private

    def hm_track_last_seen
      RedmineHmCratchmere::Tracker.touch(User.current) if User.current&.logged?
    end
  end
end
