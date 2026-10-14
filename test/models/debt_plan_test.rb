require "test_helper"

class DebtPlanTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @plan = DebtPlan.create_with_accounts!(family: @user.family, user: @user)
  end

  test "splits a card into its standard and active promo balances" do
    card = credit_cards(:one)
    card.update!(promo_apr: 0, promo_balance: 700, promo_starts_on: Date.current - 1.month,
      promo_ends_on: Date.current + 6.months)

    lines = @plan.lines(user: @user).select { |line| line[:account_id] == accounts(:credit_card).id }
    assert_equal 2, lines.size
    assert_in_delta 300, lines.first[:balance]
    assert_in_delta 700, lines.last[:balance]
    assert_equal 0, lines.last[:apr]

    card.update!(promo_balance: 2000)
    lines = @plan.lines(user: @user).select { |line| line[:account_id] == accounts(:credit_card).id }
    assert_equal 0, lines.first[:balance]
    assert_equal 1000, lines.last[:balance]
  end

  test "cash guidance honors the reserve, minimum and next biweekly payday" do
    @user.family.recurring_transactions.delete_all
    @plan.update!(cash_account_ids: [ accounts(:depository).id ], cash_float: 1000,
      payday_anchor_on: Date.new(2026, 10, 9), payday_cadence: "biweekly")
    entry = @plan.debt_plan_entries.find_by!(account: accounts(:credit_card))
    entry.update!(minimum_payment_override: 100, payment_due_day: 16)

    move = DebtPlan::NextMove.new(@plan, user: @user, on: Date.new(2026, 10, 14))
    assert_equal Date.new(2026, 10, 23), move.next_payday
    assert_equal 5000, move.available_cash
    assert_equal 100, move.committed
    assert_equal 3900, move.safe_to_send
  end

  test "cash guidance counts checking bills but not spending charged to a payoff card" do
    @user.family.recurring_transactions.delete_all
    @plan.update!(cash_account_ids: [ accounts(:depository).id ], cash_float: 1000,
      payday_anchor_on: Date.new(2026, 10, 9), payday_cadence: "biweekly")
    base = { family: @user.family, currency: "USD", expected_day_of_month: 18,
      last_occurrence_date: Date.new(2026, 9, 18), next_expected_date: Date.new(2026, 10, 18),
      status: "active", occurrence_count: 1, manual: true }
    RecurringTransaction.create!(**base, account: accounts(:depository), name: "Fictional rent", amount: 300)
    RecurringTransaction.create!(**base, account: accounts(:credit_card), name: "Fictional card charge", amount: 25)

    move = DebtPlan::NextMove.new(@plan, user: @user, on: Date.new(2026, 10, 14))
    assert_equal 300, move.committed
    assert_equal 3700, move.safe_to_send
  end

  test "monthly payday stays on the month end after February" do
    @plan.update!(payday_anchor_on: Date.new(2026, 1, 31), payday_cadence: "monthly")

    move = DebtPlan::NextMove.new(@plan, user: @user, on: Date.new(2026, 2, 28))
    assert_equal Date.new(2026, 3, 31), move.next_payday
  end

  test "achievements are idempotent when a debt reaches zero" do
    accounts(:other_liability).update!(balance: 0)
    achievements = DebtPlan::Achievements.new(@plan, user: @user)
    2.times { achievements.refresh! }

    assert_equal 1, @plan.debt_plan_events.where(key: "debt_defeated:#{accounts(:other_liability).id}").count
  end

  test "tracks the liability inflow leg of a card payment" do
    card_entry = @plan.debt_plan_entries.find_by!(account: accounts(:credit_card))
    create_transfer(from_account: accounts(:depository), to_account: accounts(:credit_card), amount: 75)

    tracker = DebtPlan::Tracker.new(@plan, user: @user)
    assert_equal 75, tracker.payments(card_entry)
  end

  test "webhook URL is limited to Discord" do
    @plan.discord_webhook_url = "https://example.com/api/webhooks/123/secret"
    assert_not @plan.valid?

    @plan.discord_webhook_url = "https://discord.com/api/webhooks/123/secret"
    assert @plan.valid?
  end
end
