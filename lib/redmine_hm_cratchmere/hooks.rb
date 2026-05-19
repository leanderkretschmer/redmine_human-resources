module RedmineHmCratchmere
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_html_head,
              partial: 'hooks/redmine_hm_cratchmere/html_head'

    render_on :view_users_form,
              partial: 'hooks/redmine_hm_cratchmere/view_users_form'
  end

  class ControllerHooks < Redmine::Hook::Listener
    def controller_users_new_before_save(context = {})
      apply_employment_type(context)
    end

    def controller_users_update_before_save(context = {})
      apply_employment_type(context)
    end

    private

    def apply_employment_type(context)
      params  = context[:params] || context[:request]&.params
      user    = context[:user]
      return unless params && user

      attrs = params[:hm_user_setting]
      return if attrs.nil?
      raw = attrs.respond_to?(:to_unsafe_h) ? attrs.to_unsafe_h : attrs.to_h
      return unless raw.key?('hm_employment_type_id') || raw.key?(:hm_employment_type_id)

      value = raw['hm_employment_type_id'] || raw[:hm_employment_type_id]
      value = nil if value.to_s.strip.empty?

      # User must be persisted to have an HmUserSetting; defer for "new"
      if user.persisted?
        setting = HmUserSetting.for(user)
        setting.update(hm_employment_type_id: value)
      else
        user.instance_variable_set(:@hm_pending_employment_type_id, value)
      end
    end
  end

  # When a brand-new user has been saved (controller_users_new_after_save),
  # flush the deferred employment type onto its freshly created HmUserSetting.
  class CreateUserHooks < Redmine::Hook::Listener
    def controller_users_new_after_save(context = {})
      user    = context[:user]
      pending = user&.instance_variable_get(:@hm_pending_employment_type_id)
      return unless user&.persisted? && pending
      HmUserSetting.for(user).update(hm_employment_type_id: pending)
    end
  end
end
