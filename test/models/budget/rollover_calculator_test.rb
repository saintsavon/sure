require "test_helper"

class Budget::RolloverCalculatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)

    @account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Rollover Checking",
      status: "active",
      currency: "USD",
      balance: 0
    )

    @category = Category.create!(
      name: "Rollover Groceries #{Time.now.to_f}",
      family: @family,
      color: "#4da568"
    )
  end

  test "disabled family zeroes out rollover_amount" do
    budget = create_budget(start_date: Date.current.beginning_of_month, budgeted_spending: 100)
    bc = create_budget_category(budget, budgeted_spending: 100)
    bc.update_column(:rollover_amount, 50) # simulate a stale value from a prior enabled period

    Budget::RolloverCalculator.new(budget).calculate!

    assert_equal 0, bc.reload.rollover_amount
  end

  test "no prior initialized budget carries in nothing" do
    @family.update!(budget_rollover_enabled: true)

    budget = create_budget(start_date: Date.current.beginning_of_month, budgeted_spending: 100)
    bc = create_budget_category(budget, budgeted_spending: 100)

    Budget::RolloverCalculator.new(budget).calculate!

    assert_equal 0, bc.reload.rollover_amount
  end

  test "positive leftover carries into the next initialized budget" do
    @family.update!(budget_rollover_enabled: true)

    older = create_budget(start_date: 2.months.ago.beginning_of_month, budgeted_spending: 500)
    create_budget_category(older, budgeted_spending: 100)
    spend(older, amount: 60) # leftover: 100 - 60 = 40

    newer = create_budget(start_date: 1.month.ago.beginning_of_month, budgeted_spending: 500)
    newer_bc = create_budget_category(newer, budgeted_spending: 50)

    Budget::RolloverCalculator.new(newer).calculate!

    assert_equal 40, newer_bc.reload.rollover_amount
  end

  test "overspending clamps the next month's carry_in to zero" do
    @family.update!(budget_rollover_enabled: true)

    older = create_budget(start_date: 2.months.ago.beginning_of_month, budgeted_spending: 500)
    create_budget_category(older, budgeted_spending: 50)
    spend(older, amount: 80) # ending balance: 50 - 80 = -30, clamped to 0

    newer = create_budget(start_date: 1.month.ago.beginning_of_month, budgeted_spending: 500)
    newer_bc = create_budget_category(newer, budgeted_spending: 50)

    Budget::RolloverCalculator.new(newer).calculate!

    assert_equal 0, newer_bc.reload.rollover_amount
  end

  test "carries forward through a multi-month chain" do
    @family.update!(budget_rollover_enabled: true)

    month_a = create_budget(start_date: 3.months.ago.beginning_of_month, budgeted_spending: 500)
    create_budget_category(month_a, budgeted_spending: 100)
    spend(month_a, amount: 60) # leftover: 40

    month_b = create_budget(start_date: 2.months.ago.beginning_of_month, budgeted_spending: 500)
    month_b_bc = create_budget_category(month_b, budgeted_spending: 50)
    spend(month_b, amount: 30) # carry_in 40 + budgeted 50 - spent 30 = 60

    month_c = create_budget(start_date: 1.month.ago.beginning_of_month, budgeted_spending: 500)
    month_c_bc = create_budget_category(month_c, budgeted_spending: 20)

    Budget::RolloverCalculator.new(month_c).calculate!

    assert_equal 40, month_b_bc.reload.rollover_amount
    assert_equal 60, month_c_bc.reload.rollover_amount
  end

  test "ring-fenced subcategory leftover is not double-counted in the parent carry-in" do
    @family.update!(budget_rollover_enabled: true)

    parent = Category.create!(name: "Bills #{Time.now.to_f}", family: @family, color: "#4da568")
    child = Category.create!(name: "Electric #{Time.now.to_f}", family: @family, color: "#4da568", parent: parent)

    older = create_budget(start_date: 2.months.ago.beginning_of_month, budgeted_spending: 500)
    BudgetCategory.create!(budget: older, category: parent, budgeted_spending: 300, currency: "USD")
    BudgetCategory.create!(budget: older, category: child, budgeted_spending: 100, currency: "USD")
    spend_on(older, category: child, amount: 60)   # ring-fenced child leftover: 100 - 60 = 40
    spend_on(older, category: parent, amount: 50)  # parent-direct spend; shared-pool leftover: (300 - 100) - 50 = 150

    newer = create_budget(start_date: 1.month.ago.beginning_of_month, budgeted_spending: 500)
    newer_parent = BudgetCategory.create!(budget: newer, category: parent, budgeted_spending: 0, currency: "USD")
    newer_child = BudgetCategory.create!(budget: newer, category: child, budgeted_spending: 0, currency: "USD")

    Budget::RolloverCalculator.new(newer).calculate!

    # Parent carries only its shared-pool leftover (150); child carries its own
    # (40). The old raw `budgeted - spent` formula double-counted the child's 40
    # into the parent (300 - 110 = 190), inflating the tree total to 230.
    assert_equal 150, newer_parent.reload.rollover_amount
    assert_equal 40, newer_child.reload.rollover_amount
    assert_equal 190, newer_parent.rollover_amount + newer_child.rollover_amount
  end

  test "a category added after the prior month carries in nothing" do
    @family.update!(budget_rollover_enabled: true)

    older = create_budget(start_date: 2.months.ago.beginning_of_month, budgeted_spending: 500)
    # `older` intentionally has no budget_category for @category

    newer = create_budget(start_date: 1.month.ago.beginning_of_month, budgeted_spending: 500)
    newer_bc = create_budget_category(newer, budgeted_spending: 50)

    Budget::RolloverCalculator.new(newer).calculate!

    assert_equal 0, newer_bc.reload.rollover_amount
  end

  private
    def create_budget(start_date:, budgeted_spending:)
      Budget.create!(
        family: @family,
        start_date: start_date,
        end_date: start_date.end_of_month,
        budgeted_spending: budgeted_spending,
        expected_income: budgeted_spending * 1.5,
        currency: "USD"
      )
    end

    def create_budget_category(budget, budgeted_spending:)
      BudgetCategory.create!(
        budget: budget,
        category: @category,
        budgeted_spending: budgeted_spending,
        currency: "USD"
      )
    end

    def spend(budget, amount:)
      spend_on(budget, category: @category, amount: amount)
    end

    def spend_on(budget, category:, amount:)
      Entry.create!(
        account: @account,
        entryable: Transaction.create!(category: category),
        date: budget.start_date,
        name: "Rollover spend",
        amount: amount,
        currency: "USD"
      )
    end
end
