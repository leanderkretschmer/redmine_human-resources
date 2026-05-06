class HmSicknessController < ApplicationController
  before_action :require_login

  helper :hm_timeclock

  def show
    @user = User.current
  end
end
