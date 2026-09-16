class BillReminderMailer < ApplicationMailer
  # Emails a family's admins a digest of bills that are overdue or coming due
  # within the family's reminder window. Mirrors RuleNotificationMailer:
  # admins only (the digest lists financial obligations), and skip delivery
  # when there is no admin or nothing is due.
  def upcoming(family:, overdue:, due_soon:)
    @family = family
    @overdue = overdue
    @due_soon = due_soon
    @bills_url = bills_url

    recipient = @family.users.find_by(role: %w[admin super_admin])
    return if recipient.nil?

    count = @overdue.size + @due_soon.size
    return if count.zero?

    mail(
      to: recipient.email,
      subject: t(".subject", count: count, product_name: product_name)
    )
  end
end
