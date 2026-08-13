require "test_helper"

class LoanTest < ActiveSupport::TestCase
  # accounts(:loan) is $500,000 backed by loans(:one) — 3.5%, 360 months, fixed.
  ORIGINATION = Date.new(2025, 1, 15)

  setup do
    @account = accounts(:loan)
    @account.entries.create!(
      date: ORIGINATION,
      name: "Opening balance",
      currency: "USD",
      amount: 500_000,
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @loan = @account.reload.loan
  end

  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    assert_equal 2245, @loan.monthly_payment.amount
  end

  test "amortization schedule covers the full term and amortizes to zero" do
    schedule = @loan.amortization_schedule

    assert_equal 360, schedule.size
    assert_equal 0, schedule.last.balance.amount
  end

  test "amortization schedule splits the first payment into interest and principal" do
    first = @loan.amortization_schedule.first

    # 500,000 * (3.5% / 12) = 1,458.33 interest. The exact payment is
    # 2,245.2234, so 786.89 goes to principal.
    assert_in_delta 1458.33, first.interest.amount, 0.01
    assert_in_delta 786.89, first.principal.amount, 0.01
    assert_in_delta 2245.22, first.payment.amount, 0.01
  end

  test "amortization schedule pays down principal faster in later periods" do
    schedule = @loan.amortization_schedule

    assert schedule.last.principal.amount > schedule.first.principal.amount
    assert schedule.last.interest.amount < schedule.first.interest.amount
  end

  test "total interest over a 500k 3.5% 30-year loan" do
    assert_in_delta 308_281.36, @loan.total_interest.amount, 0.01
  end

  test "payoff date is term_months after the opening valuation" do
    assert_equal Date.new(2055, 1, 15), @loan.payoff_date
  end

  test "amortization is unavailable for variable rate loans" do
    @loan.rate_type = "variable"

    assert_not @loan.amortizable?
    assert_empty @loan.amortization_schedule
    assert_nil @loan.payoff_date
    assert_nil @loan.total_interest
  end

  test "payments made counts elapsed periods" do
    # Origination 2025-01-15, so period 1 falls on 2025-02-15.
    travel_to Date.new(2025, 6, 20) do
      assert_equal 5, @loan.payments_made
    end
  end

  test "payments made is zero before the first payment comes due" do
    travel_to Date.new(2025, 1, 20) do
      assert_equal 0, @loan.payments_made
    end
  end

  test "payments made caps at the term" do
    travel_to Date.new(2060, 1, 1) do
      assert_equal 360, @loan.payments_made
    end
  end

  test "split payload carries principal and interest for every period" do
    payload = @loan.amortization_split_payload

    assert_equal 360, payload.size
    first = payload.first
    assert_equal Date.new(2025, 2, 15).iso8601, first[:date]
    assert_in_delta 1458.33, first[:interest].to_f, 0.01
    assert_in_delta 786.89, first[:principal].to_f, 0.01
  end

  test "interest crossover is the first period where principal overtakes interest" do
    # 500k at 3.5% over 360: principal first exceeds interest at period 124.
    assert_equal Date.new(2025, 1, 15) >> 124, @loan.interest_crossover_date
  end

  test "interest crossover is nil when the loan does not amortize" do
    @loan.rate_type = "variable"

    assert_nil @loan.interest_crossover_date
    assert_empty @loan.amortization_split_payload
  end

  test "amortization is unavailable without an opening valuation to anchor to" do
    unanchored = Account.create!(
      family: families(:dylan_family),
      name: "Unanchored Loan",
      balance: 500_000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )
    ).loan

    assert_empty unanchored.amortization_schedule
    assert_nil unanchored.payoff_date
  end
end
