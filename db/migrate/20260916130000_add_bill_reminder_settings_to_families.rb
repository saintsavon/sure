class AddBillReminderSettingsToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :bill_reminders_enabled, :boolean, default: false, null: false
    add_column :families, :bill_reminder_days_before, :integer, default: 3, null: false
    add_check_constraint :families,
      "bill_reminder_days_before >= 1 AND bill_reminder_days_before <= 30",
      name: "bill_reminder_days_before_range"
  end
end
