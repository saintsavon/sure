require "test_helper"

class CreditCardTest < ActiveSupport::TestCase
  # credit_cards(:one) is an 18.99% card on a $1,000 balance.
  TODAY = Date.new(2026, 8, 13)

  setup do
    @card = credit_cards(:one)
  end

  test "is not promotional without a promo rate and end date" do
    assert_not @card.promo?
    assert_nil @card.promo_monthly_payoff
    assert_nil @card.promo_deferred_interest_due
  end

  test "is promotional once a rate and end date are set" do
    @card.assign_attributes(promo_apr: 0, promo_ends_on: Date.new(2027, 1, 10))

    assert @card.promo?
    assert @card.promo_active?(on: TODAY)
  end

  test "promo is inactive on the day after it ends" do
    @card.assign_attributes(promo_apr: 0, promo_ends_on: TODAY)

    assert @card.promo_active?(on: TODAY)
    assert_not @card.promo_active?(on: TODAY + 1)
  end

  test "counts days until the promo ends" do
    @card.assign_attributes(promo_apr: 0, promo_ends_on: TODAY + 150)

    assert_equal 150, @card.promo_days_remaining(on: TODAY)
  end

  test "flags a promo expiring inside the warning window" do
    @card.promo_apr = 0

    @card.promo_ends_on = TODAY + 89
    assert @card.promo_expiring_soon?(on: TODAY)

    @card.promo_ends_on = TODAY + 91
    assert_not @card.promo_expiring_soon?(on: TODAY)
  end

  test "monthly payoff spreads the promo balance across whole months remaining" do
    # 2026-08-13 -> 2027-01-10 is 4 whole months: the 10th falls before the
    # 13th, so January's statement lands after the promo has already died.
    @card.assign_attributes(promo_apr: 0, promo_balance: 9_367, promo_ends_on: Date.new(2027, 1, 10))

    assert_in_delta 2_341.75, @card.promo_monthly_payoff(on: TODAY).amount, 0.01
  end

  test "monthly payoff is the whole balance once no full month remains" do
    @card.assign_attributes(promo_apr: 0, promo_balance: 800, promo_ends_on: TODAY + 5)

    assert_equal 800, @card.promo_monthly_payoff(on: TODAY).amount
  end

  test "waived-interest promos carry no retroactive charge" do
    @card.assign_attributes(promo_apr: 0, promo_balance: 9_367,
      promo_starts_on: Date.new(2026, 1, 10), promo_ends_on: Date.new(2027, 1, 10))

    assert_not @card.promo_deferred_interest?
    assert_nil @card.promo_deferred_interest_due
  end

  test "deferred-interest promos bill every month back to the promo start" do
    # 12 months at 18.99% on $800 billed at once if any balance survives.
    @card.assign_attributes(promo_apr: 0, promo_balance: 800, promo_deferred_interest: true,
      promo_starts_on: Date.new(2026, 1, 10), promo_ends_on: Date.new(2027, 1, 10))

    assert_in_delta 151.92, @card.promo_deferred_interest_due.amount, 0.01
  end

  test "deferred-interest promos require the start date the charge accrues from" do
    @card.assign_attributes(promo_apr: 0, promo_balance: 800, promo_deferred_interest: true,
      promo_ends_on: Date.new(2027, 1, 10))

    assert_not @card.valid?
    assert_includes @card.errors[:promo_starts_on], "can't be blank"
  end

  test "monthly interest at the go-to rate is what the balance costs after reset" do
    @card.assign_attributes(promo_apr: 0, promo_balance: 9_367, promo_ends_on: Date.new(2027, 1, 10))

    # 9,367 * 18.99% / 12
    assert_in_delta 148.23, @card.promo_reset_monthly_interest.amount, 0.01
  end

  test "reset interest is unknown without a go-to rate" do
    @card.assign_attributes(apr: nil, promo_apr: 0, promo_balance: 9_367, promo_ends_on: Date.new(2027, 1, 10))

    assert_nil @card.promo_reset_monthly_interest
  end
end
