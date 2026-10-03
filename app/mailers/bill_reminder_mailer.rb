class BillReminderMailer < ApplicationMailer
  # Emails a family's admins a digest of bills that are overdue or coming due
  # within the family's reminder window. Mirrors RuleNotificationMailer:
  # admins only (the digest lists financial obligations), and skip delivery
  # when there is no admin or nothing is due.
  def upcoming(family:, recipient:, overdue:, due_soon:)
    @family = family
    @overdue = overdue
    @due_soon = due_soon
    @bills_url = bills_url

    return unless recipient.family_id == family.id && recipient.admin?

    count = @overdue.size + @due_soon.size
    return if count.zero?

    mail(
      to: recipient.email,
      subject: t(".subject", count: count, product_name: product_name)
    )
  end
end
