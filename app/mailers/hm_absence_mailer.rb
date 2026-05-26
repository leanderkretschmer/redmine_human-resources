class HmAbsenceMailer < Mailer
  helper :hm_timeclock

  # Redmine's Mailer#process requires a User as the first argument so it can
  # switch User.current and the I18n locale for the duration of the mail
  # rendering. We honour that by always passing a User first; for the
  # "requested" mail the recipient is whatever was configured in the plugin
  # settings (admin addresses), while the *context* user is the requester.

  def absence_requested(user, recipients, absence_id)
    @absence   = HmAbsence.find(absence_id)
    @user      = @absence.user
    @breakdown = @absence.breakdown
    @conflicts = @absence.conflicts(padding_days: ::RedmineHumanResources::Notifications.conflict_padding_days).to_a
    mail to: recipients,
         subject: I18n.t(:mail_subject_hm_absence_requested,
                         user: @user.name,
                         kind: HmAbsence.kind_label(@absence.kind))
  end

  def absence_decided(user, absence_id)
    @absence   = HmAbsence.find(absence_id)
    @user      = @absence.user
    @breakdown = @absence.breakdown
    return if @user.mail.blank?
    mail to: @user.mail,
         subject: I18n.t(:mail_subject_hm_absence_decided,
                         status: HmAbsence.status_label(@absence.status),
                         kind:   HmAbsence.kind_label(@absence.kind))
  end

  def absence_edited(user, absence_id, editor_id)
    @absence   = HmAbsence.find(absence_id)
    @editor    = User.find(editor_id)
    @user      = @absence.user
    @breakdown = @absence.breakdown
    return if @user.mail.blank?
    mail to: @user.mail,
         subject: I18n.t(:mail_subject_hm_absence_edited,
                         editor: @editor.name,
                         kind:   HmAbsence.kind_label(@absence.kind))
  end

  def self.deliver_absence_requested(absence)
    return unless absence&.vacation?
    recipients = ::RedmineHumanResources::Notifications.recipients
    return if recipients.empty?
    user = absence.user
    return unless user
    ::RedmineHumanResources::Notifications.deliver_message(
      absence_requested(user, recipients, absence.id)
    )
  end

  def self.deliver_absence_decided(absence)
    return unless absence&.vacation?
    user = absence.user
    return unless user
    ::RedmineHumanResources::Notifications.deliver_message(
      absence_decided(user, absence.id)
    )
  end

  def self.deliver_absence_edited(absence, editor)
    return unless absence&.vacation? && editor
    return if absence.user_id == editor.id
    user = absence.user
    return unless user
    ::RedmineHumanResources::Notifications.deliver_message(
      absence_edited(user, absence.id, editor.id)
    )
  end
end
