module RedmineHmCratchmere
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_html_head,
              partial: 'hooks/redmine_hm_cratchmere/html_head'

    render_on :view_users_form,
              partial: 'hooks/redmine_hm_cratchmere/view_users_form'
  end

  class ControllerHooks < Redmine::Hook::Listener
    def controller_users_new_before_save(context = {})
      apply_hm_settings(context)
    end

    def controller_users_update_before_save(context = {})
      apply_hm_settings(context)
    end

    private

    def apply_hm_settings(context)
      params  = context[:params] || context[:request]&.params
      user    = context[:user]
      return unless params && user

      attrs = params[:hm_user_setting]
      return if attrs.nil?
      raw = attrs.respond_to?(:to_unsafe_h) ? attrs.to_unsafe_h : attrs.to_h

      changes = {}
      if raw.key?('hm_employment_type_id') || raw.key?(:hm_employment_type_id)
        v = raw['hm_employment_type_id'] || raw[:hm_employment_type_id]
        changes[:hm_employment_type_id] = v.to_s.strip.empty? ? nil : v
      end
      if raw.key?('region_code') || raw.key?(:region_code)
        v = raw['region_code'] || raw[:region_code]
        changes[:region_code] = v.to_s.strip.empty? ? nil : v
      end
      return if changes.empty?

      if user.persisted?
        HmUserSetting.for(user).update(changes)
      else
        user.instance_variable_set(:@hm_pending_settings, changes)
      end
    end
  end

  # When a brand-new user has been saved (controller_users_new_after_save),
  # flush the deferred settings onto its freshly created HmUserSetting.
  class CreateUserHooks < Redmine::Hook::Listener
    def controller_users_new_after_save(context = {})
      user    = context[:user]
      pending = user&.instance_variable_get(:@hm_pending_settings)
      return unless user&.persisted? && pending.present?
      HmUserSetting.for(user).update(pending)
    end
  end
end
