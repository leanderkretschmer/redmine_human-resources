require 'csv'

class HmAdminImportsController < ApplicationController
  before_action :require_admin

  helper :hm_timeclock

  COLUMNS = %w[login date start end break_minutes notes].freeze
  MAX_ROWS = 2000

  def new
  end

  def template
    csv = CSV.generate do |out|
      out << COLUMNS
      out << ['jdoe',        '2026-05-01', '09:00', '17:30', '30', 'Beispiel Tagschicht']
      out << ['mmuster',     '2026-05-01', '22:00', '02:00', '0',  'Beispiel Nachtschicht (über Mitternacht)']
    end
    send_data csv, filename: 'hm_timeclock_import_template.csv', type: 'text/csv; charset=utf-8'
  end

  def preview
    file = params[:file]
    if file.blank?
      flash.now[:error] = l(:notice_hm_import_no_file)
      return render :new
    end

    @rows = parse_csv(file.read)
    if @rows.empty?
      flash.now[:error] = l(:notice_hm_import_empty)
      return render :new
    end
    @users = User.active.sorted.to_a
  rescue StandardError => e
    flash.now[:error] = l(:notice_hm_import_parse_error, message: e.message)
    render :new
  end

  def commit
    rows = Array(params[:rows]&.values)
    created = 0
    skipped = 0
    errors  = []

    HmWorkEntry.transaction do
      rows.each_with_index do |row, idx|
        next if row[:include].to_s != '1'
        user_id = row[:user_id].to_i
        if user_id.zero?
          skipped += 1
          next
        end
        started_at, ended_at = build_times(row[:date], row[:start], row[:end])
        if started_at.nil? || ended_at.nil?
          errors << l(:notice_hm_import_row_invalid, row: idx + 1)
          skipped += 1
          next
        end

        entry = HmWorkEntry.create!(
          user_id:    user_id,
          started_at: started_at,
          ended_at:   ended_at,
          state:      HmWorkEntry::STATE_COMPLETED,
          notes:      [row[:notes].presence, l(:notice_hm_import_note_suffix)].compact.join(' · ')
        )
        brk = row[:break_minutes].to_i
        if brk.positive?
          HmBreakEntry.create!(hm_work_entry_id: entry.id,
                               started_at: started_at,
                               ended_at:   started_at + brk.minutes)
        end
        created += 1
      end
    end

    flash[:notice] = l(:notice_hm_import_done, created: created, skipped: skipped)
    flash[:error]  = errors.join(' · ') if errors.any?
    redirect_to hr_admin_import_path
  rescue StandardError => e
    flash[:error] = l(:notice_hm_import_commit_error, message: e.message)
    redirect_to hr_admin_import_path
  end

  private

  def parse_csv(content)
    content = content.to_s
    # Strip BOM and detect delimiter (comma or semicolon).
    content = content.sub("\xEF\xBB\xBF".dup.force_encoding('UTF-8'), '') if content.respond_to?(:sub)
    sep = content.lines.first.to_s.count(';') > content.lines.first.to_s.count(',') ? ';' : ','
    table = CSV.parse(content, headers: true, col_sep: sep, skip_blanks: true)

    by_login = {}
    rows = []
    table.each do |csv_row|
      break if rows.size >= MAX_ROWS
      h = csv_row.to_h.transform_keys { |k| k.to_s.strip.downcase }
      login = h['login'].to_s.strip
      date  = h['date'].to_s.strip
      start = h['start'].to_s.strip
      finish = h['end'].to_s.strip
      next if date.blank? && start.blank? && finish.blank? && login.blank?

      user = if login.present?
               by_login[login.downcase] ||= lookup_user(login)
             end
      started_at, ended_at = build_times(date, start, finish)
      rows << {
        login: login,
        date: date,
        start: start,
        end: finish,
        break_minutes: h['break_minutes'].to_s.strip,
        notes: h['notes'].to_s.strip,
        user_id: user&.id,
        user_name: user&.name,
        valid: !(started_at.nil? || ended_at.nil?),
        gross_label: (started_at && ended_at) ? format('%d:%02d', ((ended_at - started_at) / 3600).to_i, (((ended_at - started_at) % 3600) / 60).to_i) : nil
      }
    end
    rows
  end

  # Match a CSV identifier against login first, then any registered e-mail
  # address (Redmine stores e-mails in the email_addresses table, not on users).
  def lookup_user(identifier)
    id = identifier.to_s.strip.downcase
    return nil if id.blank?
    user = User.where('LOWER(login) = ?', id).first
    return user if user
    addr = EmailAddress.where('LOWER(address) = ?', id).first
    addr&.user
  end

  # date "YYYY-MM-DD", start/end "HH:MM"; end<=start rolls to the next day.
  def build_times(date_str, start_str, end_str)
    return [nil, nil] if date_str.blank? || start_str.blank? || end_str.blank?
    tz = Time.zone
    d = Date.parse(date_str) rescue (return [nil, nil])
    sh, sm = start_str.split(':').map(&:to_i)
    eh, em = end_str.split(':').map(&:to_i)
    return [nil, nil] if [sh, sm, eh, em].any?(&:nil?)
    started = tz.local(d.year, d.month, d.day, sh, sm)
    ended   = tz.local(d.year, d.month, d.day, eh, em)
    ended += 1.day if ended <= started
    [started, ended]
  rescue StandardError
    [nil, nil]
  end
end
