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

    paid = entry.payment_due_day ? payments_for_due(entry, due: next_due_date(entry), to: @on) : payments(entry)
    paid >= entry.minimum_payment.to_d
  end

  def next_due_date(entry)
    due = due_date_in(@on, entry.payment_due_day)
    due >= @on ? due : due_date_in(@on.next_month, entry.payment_due_day)
  end

  def payments_for_due(entry, due:, to: due)
    previous_due = due_date_in(due.prev_month, entry.payment_due_day)
    payments(entry, from: previous_due + 1, to:)
  end

  def actual_total
    @plan.total_owed(user: @user)
  end

  def baseline_gap
    return nil if @plan.baseline_taken_on.blank? || @plan.baseline_schedule.empty?
    return nil unless @plan.visible_entries(@user).count == @plan.debt_plan_entries.count

    baseline_expected_total - actual_total
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
    def due_date_in(month, day)
      Date.new(month.year, month.month, [ day, month.end_of_month.day ].min)
    end

    def baseline_expected_total
      schedule = @plan.baseline_schedule
      start_date = @plan.baseline_taken_on
      return schedule.first.to_d if @on <= start_date

      index = (@on.year - start_date.year) * 12 + @on.month - start_date.month
      return schedule.last.to_d if index >= schedule.length - 1

      period_start = index.zero? ? start_date : @on.beginning_of_month - 1
      period_end = @on.end_of_month
      progress = (@on - period_start).to_d / (period_end - period_start)
      schedule[index].to_d + (schedule[index + 1].to_d - schedule[index].to_d) * progress
    end

    def transaction_entries(entry, from:, to:)
      Entry.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: entry.account_id, date: from..to, excluded: false)
        .excluding_pending.excluding_split_parents
    end
end
