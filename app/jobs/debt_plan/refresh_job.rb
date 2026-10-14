class DebtPlan::RefreshJob < ApplicationJob
  queue_as :default

  def perform(family_id)
    plan = Family.find_by(id: family_id)&.debt_plan
    return unless plan

    user = plan.family.users.where(role: %w[admin super_admin]).first
    return unless user

    projection = plan.project(user:)
    plan.debt_plan_snapshots.find_or_initialize_by(taken_on: Date.current).tap do |snapshot|
      snapshot.total_debt = plan.total_owed(user:)
      snapshot.projected_debt_free_on = if projection.debt_free_month == 0
        Date.current
      elsif projection.debt_free_month
        Date.current.beginning_of_month >> (projection.debt_free_month - 1)
      end
      snapshot.projected_total_interest = projection.total_interest.round(2)
      snapshot.payload = { balances: projection.lines.map { |line| [ line[:account_id], line[:balance] ] } }
      snapshot.save!
    end
    DebtPlan::Achievements.new(plan, user:).refresh!
    record_risks(plan, user, projection)
    DebtPlan::EmailNotifyJob.perform_later(plan.id) if plan.email_notifications_enabled?
    DebtPlan::DiscordNotifyJob.perform_later(plan.id) if plan.discord_notifications_enabled?
  end

  private
    def record_risks(plan, user, projection)
      tracker = DebtPlan::Tracker.new(plan, user:)
      plan.visible_entries(user).each do |entry|
        card = entry.account.accountable
        if card.is_a?(CreditCard) && card.promo_active? && card.promo_days_remaining <= 30 && card.promo_balance.to_d.positive?
          promo_index = projection.lines.each_index.find { |index| projection.lines[index][:entry_id] == entry.id && projection.lines[index][:promo] }
          misses = promo_index && (projection.payoff_month(promo_index).nil? || projection.payoff_month(promo_index) > projection.lines[promo_index][:promo_last_month])
          record(plan, "promo_risk", "promo_risk:#{entry.account_id}:#{Date.current.strftime('%Y-%m')}", entry.account) if misses
        end
        next unless entry.payment_due_day && !tracker.minimum_covered?(entry)

        due = Date.new(Date.current.year, Date.current.month, [ entry.payment_due_day, Date.current.end_of_month.day ].min)
        record(plan, "minimum_due", "minimum_due:#{entry.account_id}:#{due}", entry.account) if (due - Date.current).to_i.between?(0, 3)
      end
    end

    def record(plan, kind, key, account)
      plan.debt_plan_events.find_or_create_by!(key:) do |event|
        event.kind = kind
        event.account = account
        event.occurred_on = Date.current
      end
    end
end
