class CreateHmAbsenceAudits < ActiveRecord::Migration[7.0]
  def change
    create_table :hm_absence_audits do |t|
      t.references :hm_absence, type: :integer, null: false, foreign_key: true, index: true
      t.integer :actor_id, null: false
      t.string  :action, null: false, limit: 24
      t.string  :from_status, limit: 16
      t.string  :to_status,   limit: 16
      t.text    :notes
      t.timestamps
    end
    add_index :hm_absence_audits, [:hm_absence_id, :created_at]
    add_index :hm_absence_audits, :actor_id
  end
end
