class DebtPlanMailer < ApplicationMailer
  def digest(plan:, recipient:, events:)
    return unless recipient.family_id == plan.family_id && recipient.admin? && events.any?

    @events = events
    @payoff_url = payoff_url
    mail(to: recipient.email, subject: t(".subject", product_name: product_name))
  end
end
