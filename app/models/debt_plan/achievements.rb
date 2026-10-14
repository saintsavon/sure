class DebtPlan::Achievements
  MILESTONES = [ 10, 25, 50, 75, 90, 100 ].freeze

  def initialize(plan, user:, on: Date.current)
    @plan = plan
    @user = user
    @on = on
  end

  def refresh!
    entries = @plan.visible_entries(@user).reject { |entry| entry.role == "excluded" }
    starting = entries.sum { |entry| entry.starting_balance.to_d }
    remaining = entries.sum { |entry| [ entry.account.balance.to_d, 0 ].max }
    if starting.positive?
      percent = ((starting - remaining) / starting * 100).to_f
      MILESTONES.each do |threshold|
        record("milestone", "milestone:#{threshold}", payload: { percent: threshold }) if percent >= threshold
      end
    end
    entries.each do |entry|
      next unless entry.starting_balance.to_d.positive? && entry.account.balance.to_d <= 0.005

      record("debt_defeated", "debt_defeated:#{entry.account_id}", account: entry.account)
      card = entry.account.accountable
      if card.is_a?(CreditCard) && card.promo_ends_on && @on <= card.promo_ends_on
        record("promo_beaten", "promo_beaten:#{entry.account_id}", account: entry.account)
      end
    end
    high_interest = entries.select { |entry| entry.apr.to_d / 100 >= @plan.high_interest_line.to_d && entry.starting_balance.to_d.positive? }
    if high_interest.any? && high_interest.all? { |entry| entry.account.balance.to_d <= 0.005 }
      record("high_interest_cleared", "high_interest_cleared")
    end
    goal = @plan.emergency_fund_goal
    if goal && goal.target_amount.to_d.positive?
      percent = goal.current_balance.amount.to_d / goal.target_amount.to_d * 100
      [ 25, 50, 75, 100 ].each do |threshold|
        record("emergency_fund", "emergency_fund:#{threshold}", payload: { percent: threshold }) if percent >= threshold
      end
    end
    record_minimum_streak(entries)
    record_frozen_streak(entries)
    record_extra_streak(entries)
    record_zero_card_interest(entries)
  end

  private
    def record_minimum_streak(entries)
      dated = entries.select { |entry| entry.payment_due_day && entry.minimum_payment.to_d.positive? }
      return if dated.empty?

      month = @on.prev_month.beginning_of_month
      tracker = DebtPlan::Tracker.new(@plan, user: @user, on: month.end_of_month)
      return unless dated.all? do |entry|
        due = Date.new(month.year, month.month, [ entry.payment_due_day, month.end_of_month.day ].min)
        tracker.payments_for_due(entry, due:) >= entry.minimum_payment.to_d
      end

      record_streak("minimums", month)
    end

    def record_frozen_streak(entries)
      cards = entries.select { |entry| entry.frozen_card? && entry.account.accountable.is_a?(CreditCard) }
      return if cards.empty?

      month = @on.prev_month.beginning_of_month
      return unless cards.all? do |entry|
        balances = entry.account.balances.where(date: month..month.end_of_month).order(:date)
        balances.exists? && balances.first.end_balance.to_d >= balances.last.end_balance.to_d
      end

      record_streak("frozen", month)
    end

    def record_extra_streak(entries)
      target = [ @plan.monthly_surplus.to_d, 0 ].max
      return if target.zero? || entries.empty?

      month = @on.prev_month.beginning_of_month
      tracker = DebtPlan::Tracker.new(@plan, user: @user, on: month.end_of_month)
      extra = entries.sum { |entry| [ tracker.payments(entry, from: month, to: month.end_of_month) - entry.minimum_payment.to_d, 0 ].max }
      record_streak("extra", month) if extra >= target
    end

    def record_zero_card_interest(entries)
      cards = entries.select { |entry| entry.account.accountable.is_a?(CreditCard) }
      return if cards.empty?

      month = @on.prev_month.beginning_of_month
      tracker = DebtPlan::Tracker.new(@plan, user: @user)
      prior = month.prev_month
      prior_interest = cards.sum { |entry| tracker.interest(entry, from: prior, to: prior.end_of_month) }
      current_interest = cards.sum { |entry| tracker.interest(entry, from: month, to: month.end_of_month) }
      record("zero_card_interest", "zero_card_interest:#{month.strftime('%Y-%m')}") if prior_interest.positive? && current_interest.zero?
    end

    def record_streak(type, month)
      prior_event = @plan.debt_plan_events.find_by(key: "streak:#{type}:#{month.prev_month.strftime('%Y-%m')}")
      count = prior_event ? prior_event.payload.fetch("count", 0).to_i + 1 : 1
      record("streak", "streak:#{type}:#{month.strftime('%Y-%m')}", payload: { type:, count: })
    end

    def record(kind, key, account: nil, payload: {})
      @plan.debt_plan_events.find_or_create_by!(key:) do |event|
        event.kind = kind
        event.account = account
        event.occurred_on = @on
        event.payload = payload
      end
    end
end
