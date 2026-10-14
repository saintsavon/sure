class DebtPlan::EmailNotifyJob < ApplicationJob
  queue_as :mailers

  def perform(plan_id)
    plan = DebtPlan.find_by(id: plan_id)
    return unless plan&.active? && plan.email_notifications_enabled?

    plan.with_lock do
      next if plan.email_digest_sent_on == Date.current
      events = plan.debt_plan_events.where(email_notified_at: nil).order(:created_at).to_a
      next if events.empty?

      plan.family.users.where(role: %w[admin super_admin]).find_each do |recipient|
        accessible_ids = plan.family.accounts.accessible_by(recipient).pluck(:id)
        visible_events = events.select { |event| event.account_id.nil? || accessible_ids.include?(event.account_id) }
        DebtPlanMailer.digest(plan:, recipient:, events: visible_events).deliver_now if visible_events.any?
      end
      plan.debt_plan_events.where(id: events.map(&:id)).update_all(email_notified_at: Time.current)
      plan.update!(email_digest_sent_on: Date.current)
    end
  end
end
