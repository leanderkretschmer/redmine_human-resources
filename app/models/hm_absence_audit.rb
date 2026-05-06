class HmAbsenceAudit < ActiveRecord::Base
  self.table_name = 'hm_absence_audits'

  ACTION_CREATED  = 'created'.freeze
  ACTION_UPDATED  = 'updated'.freeze
  ACTION_APPROVED = 'approved'.freeze
  ACTION_REJECTED = 'rejected'.freeze
  ACTION_RESET    = 'reset'.freeze
  ACTIONS         = [ACTION_CREATED, ACTION_UPDATED, ACTION_APPROVED, ACTION_REJECTED, ACTION_RESET].freeze

  belongs_to :hm_absence
  belongs_to :actor, class_name: 'User'

  validates :action, inclusion: { in: ACTIONS }

  def self.action_label(action)
    case action
    when ACTION_CREATED  then I18n.t(:label_hm_audit_action_created)
    when ACTION_UPDATED  then I18n.t(:label_hm_audit_action_updated)
    when ACTION_APPROVED then I18n.t(:label_hm_audit_action_approved)
    when ACTION_REJECTED then I18n.t(:label_hm_audit_action_rejected)
    when ACTION_RESET    then I18n.t(:label_hm_audit_action_reset)
    else action.to_s.humanize
    end
  end
end
