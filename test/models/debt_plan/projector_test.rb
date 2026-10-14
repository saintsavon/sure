require "test_helper"

class DebtPlan::ProjectorTest < ActiveSupport::TestCase
  test "matches the fictional reference waterfall for both strategies" do
    golden = JSON.parse(Rails.root.join("test/fixtures/files/debt_plan_golden.json").read)

    %w[snowball avalanche].each do |strategy|
      input = golden.fetch("plan")
      debts = golden.fetch("debts")
      expected = golden.fetch("expected").fetch(strategy)
      projection = DebtPlan::Projector.new(lines: debts, strategy:,
        high_interest_line: input.fetch("high_interest_line"),
        base_surplus: input.fetch("base_surplus"), lumps: input.fetch("lumps"),
        scheduled_months: input.fetch("scheduled_months"),
        scheduled_amount: input.fetch("scheduled_amount"), months: input.fetch("months"))

      debts.each_with_index do |debt, index|
        assert_equal expected.fetch("payoff_month").fetch(debt.fetch("name")), projection.payoff_month(index), "#{strategy}: #{debt['name']}"
        assert_in_delta expected.fetch("first_month_extra").fetch(debt.fetch("name")), projection.rows.first.extra[index], 0.01
      end
      assert_in_delta expected.fetch("interest_12"), projection.total_interest(12), 0.01
      assert_in_delta expected.fetch("interest_24"), projection.total_interest(24), 0.01
      expected.fetch("total_balance_by_month").each_with_index do |balance, index|
        assert_in_delta balance, projection.total_balance_by_month[index], 0.01, "#{strategy}: month #{index + 1}"
      end
    end
  end

  test "zero and excluded balances never receive extra" do
    lines = [
      { name: "Credit", balance: -5, apr: 0.3, minimum: 0, role: "snowball" },
      { name: "Excluded", balance: 100, apr: 0.4, minimum: 0, role: "excluded" },
      { name: "Target", balance: 100, apr: 0.2, minimum: 0, role: "snowball" }
    ]
    projection = DebtPlan::Projector.new(lines:, strategy: "snowball", high_interest_line: 0.15,
      base_surplus: [ 50 ], months: 1)

    assert_equal 0, projection.rows.first.extra[0]
    assert_equal 0, projection.rows.first.extra[1]
    assert_operator projection.rows.first.extra[2], :>, 0
  end
end
