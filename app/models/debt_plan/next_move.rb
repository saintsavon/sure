class DebtPlan::NextMove
  attr_reader :next_payday, :available_cash, :committed, :safe_to_send

  def initialize(plan, user:, on: Date.current)
    @plan = plan
    @user = user
    @on = on
    @next_payday = calculate_next_payday
    unless next_payday
      @available_cash = 0.to_d
      @committed = 0.to_d
      @safe_to_send = 0.to_d
      return
    end
    accessible_cash = plan.family.accounts.accessible_by(user).visible.assets.where(accountable_type: "Depository", id: plan.cash_account_ids)
    @available_cash = accessible_cash.sum { |account| [ account.balance.to_d, 0 ].max }
    entries = plan.visible_entries(user).reject { |entry| entry.role == "excluded" }
    debt_ids = entries.map(&:account_id)
    bills = plan.family.recurring_transactions.bills.accessible_by(user)
      .where(next_expected_date: on..next_payday).to_a
      .reject { |bill| debt_ids.include?(bill.account_id) }
    bill_amount = bills.sum { |bill| [ bill.display_amount.to_d, 0 ].max }
    tracker = DebtPlan::Tracker.new(plan, user:, on:)
    minimums = entries.sum do |entry|
      next 0 unless entry.payment_due_day

      due = tracker.next_due_date(entry)
      next 0 unless due <= next_payday

      scheduled = bills.sum do |bill|
        bill.destination_account_id == entry.account_id && bill.next_expected_date <= due ?
          [ bill.display_amount.to_d, 0 ].max : 0
      end
      [ entry.minimum_payment.to_d - tracker.payments_for_due(entry, due:, to: on) - scheduled, 0 ].max
    end
    @committed = bill_amount + minimums
    @safe_to_send = [ available_cash - plan.cash_float.to_d - committed, 0 ].max
  end

  def allocations(projection)
    amount = safe_to_send.to_f
    first = projection.rows.first
    return [] unless first

    allocations = projection.lines.each_with_index.sort_by { |_, index| [ first.rank[index], index ] }.filter_map do |line, index|
      next if line[:savings_goal] || %w[minimum_only scheduled excluded].include?(line[:role]) || amount <= 0
      next if line[:balance].to_f <= 0

      send_amount = [ amount, line[:balance].to_f ].min
      amount -= send_amount
      { name: line[:name], amount: send_amount, account_id: line[:account_id] }
    end
    allocations.group_by { |allocation| allocation[:account_id] }.values.map do |group|
      { name: group.first[:name], amount: group.sum { |allocation| allocation[:amount] }, account_id: group.first[:account_id] }
    end
  end

  private
    def calculate_next_payday
      anchor = @plan.payday_anchor_on
      return nil unless anchor

      case @plan.payday_cadence
      when "weekly", "biweekly"
        interval = @plan.payday_cadence == "weekly" ? 7 : 14
        anchor += interval while anchor <= @on
        anchor
      when "monthly"
        period = 0
        period += 1 while (anchor >> period) <= @on
        anchor >> period
      when "semimonthly"
        candidates = [ @on.beginning_of_month, @on.next_month.beginning_of_month ].flat_map do |month|
          days = [ anchor.day, [ anchor.day + 15, month.end_of_month.day ].min ].uniq
          days.map { |day| Date.new(month.year, month.month, [ day, month.end_of_month.day ].min) }
        end
        candidates.select { |date| date > @on }.min
      end
    end
end
