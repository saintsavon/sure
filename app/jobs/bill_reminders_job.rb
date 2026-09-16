class BillRemindersJob < ApplicationJob
  queue_as :scheduled

  # How many days past its due date a bill keeps appearing in reminder emails.
  # Bounds the nag: an unpaid overdue bill is emailed for at most (the reminder
  # window + this many) days rather than every day forever. It still shows on
  # the Bills page the whole time. A per-bill "last reminded" throttle is a
  # follow-up.
  OVERDUE_REMINDER_GRACE_DAYS = 7

  # Emails each opted-in family's admins a digest of bills that are overdue or
  # coming due within their reminder window. Scheduled daily via
  # config/schedule.yml. No-op for families that haven't opted in or have
  # nothing due.
  def perform
    Family.where(bill_reminders_enabled: true).find_each do |family|
      window = (Date.current - OVERDUE_REMINDER_GRACE_DAYS)..(Date.current + family.bill_reminder_days_before)

      due = family.recurring_transactions
                  .bills
                  .where(next_expected_date: window)
                  .includes(:merchant, :account)
                  .to_a

      by_status = due.group_by { |bill| bill.bill_status(reminder_days: family.bill_reminder_days_before) }
      overdue  = (by_status[:overdue]  || []).sort_by(&:due_date)
      due_soon = (by_status[:due_soon] || []).sort_by(&:due_date)

      next if overdue.empty? && due_soon.empty?

      BillReminderMailer.upcoming(family: family, overdue: overdue, due_soon: due_soon).deliver_later
    end
  end
end
