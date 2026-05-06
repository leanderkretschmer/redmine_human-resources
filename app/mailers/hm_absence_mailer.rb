class HmAbsenceMailer < Mailer
  helper :hm_timeclock

  def absence_requested(recipients, absence_id)
    @absence   = HmAbsence.find(absence_id)
    @user      = @absence.user
    @breakdown = @absence.breakdown
    @conflicts = @absence.conflicts(padding_days: ::RedmineHmCratchmere::Notifications.conflict_padding_days).to_a
    mail to: recipients,
         subject: I18n.t(:mail_subject_hm_absence_requested,
                         user: @user.name,
                         kind: HmAbsence.kind_label(@absence.kind))
  end

  def absence_decided(absence_id)
    @absence   = HmAbsence.find(absence_id)
    @user      = @absence.user
    @breakdown = @absence.breakdown
    return if @user.mail.blank?
    mail to: @user.mail,
         subject: I18n.t(:mail_subject_hm_absence_decided,
                         status: HmAbsence.status_label(@absence.status),
                         kind:   HmAbsence.kind_label(@absence.kind))
  end

  def absence_edited(absence_id, editor_id)
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
    recipients = ::RedmineHmCratchmere::Notifications.recipients
    return if recipients.empty?
    ::RedmineHmCratchmere::Notifications.deliver_message(
      absence_requested(recipients, absence.id)
    )
  end

  def self.deliver_absence_decided(absence)
    return unless absence&.vacation?
    ::RedmineHmCratchmere::Notifications.deliver_message(
      absence_decided(absence.id)
    )
  end

  def self.deliver_absence_edited(absence, editor)
    return unless absence&.vacation? && editor
    return if absence.user_id == editor.id
    ::RedmineHmCratchmere::Notifications.deliver_message(
      absence_edited(absence.id, editor.id)
    )
  end
end
