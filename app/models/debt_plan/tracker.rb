class DebtPlan::Tracker
  def initialize(plan, user:, on: Date.current)
    @plan = plan
    @user = user
    @on = on
  end

  def payments(entry, from: @on.beginning_of_month, to: @on)
    transaction_entries(entry, from:, to:)
      .where("entries.amount < 0")
      .where(transactions: { kind: %w[funds_movement cc_payment loan_payment] })
      .sum("-entries.amount")
  end

  def interest(entry, from: @on.beginning_of_month, to: @on)
    transaction_entries(entry, from:, to:)
      .where("entries.amount > 0")
      .where("entries.name ~* ?", "(interest charge|purchase interest|interest charged)")
      .sum("entries.amount")
  end

  def minimum_covered?(entry)
    return true if entry.minimum_payment.to_d.zero?

    payments(entry) >= entry.minimum_payment.to_d
  end

  def actual_total
    @plan.total_owed(user: @user)
  end

  def baseline_gap
    return nil if @plan.baseline_taken_on.blank? || @plan.baseline_schedule.empty?
    return nil unless @plan.visible_entries(@user).count == @plan.debt_plan_entries.count

    index = (@on.year - @plan.baseline_taken_on.year) * 12 + @on.month - @plan.baseline_taken_on.month
    expected = @plan.baseline_schedule[[ index, 0 ].max]
    expected && expected.to_d - actual_total
  end

  def baseline_month_delta
    return nil unless baseline_gap

    current_index = (@on.year - @plan.baseline_taken_on.year) * 12 + @on.month - @plan.baseline_taken_on.month
    closest_index = @plan.baseline_schedule.each_with_index.min_by do |balance, _index|
      (balance.to_d - actual_total).abs
    end&.last
    closest_index && closest_index - [ current_index, 0 ].max
  end

  private
    def transaction_entries(entry, from:, to:)
      Entry.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: entry.account_id, date: from..to, excluded: false)
        .excluding_pending.excluding_split_parents
    end
end
