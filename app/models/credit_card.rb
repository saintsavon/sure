class CreditCard < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "credit_card"

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

  # How far out an expiring promo is worth warning about.
  PROMO_WARNING_WINDOW = 90

  # Deferred interest accrues from the promo start, so the figure is
  # meaningless without it.
  validates :promo_starts_on, presence: true, if: :promo_deferred_interest?
  validates :promo_apr, :promo_balance, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :promo_ends_on,
            comparison: { greater_than_or_equal_to: :promo_starts_on },
            if: -> { promo_starts_on.present? && promo_ends_on.present? }

  class << self
    def color
      "#F13636"
    end

    def icon
      "credit-card"
    end

    def classification
      "liability"
    end
  end

  def available_credit_money
    available_credit ? Money.new(available_credit, account.currency) : nil
  end

  def minimum_payment_money
    minimum_payment ? Money.new(minimum_payment, account.currency) : nil
  end

  def annual_fee_money
    annual_fee ? Money.new(annual_fee, account.currency) : nil
  end

  # #apr is the go-to rate — what the card charges once any promo has ended.
  def promo?
    promo_apr.present? && promo_ends_on.present?
  end

  def promo_active?(on: Date.current)
    promo? && on <= promo_ends_on
  end

  def promo_days_remaining(on: Date.current)
    return nil unless promo?

    (promo_ends_on - on).to_i
  end

  def promo_expiring_soon?(on: Date.current)
    promo_active?(on: on) && promo_days_remaining(on: on) < PROMO_WARNING_WINDOW
  end

  def promo_balance_money
    promo_balance ? Money.new(promo_balance, account.currency) : nil
  end

  # What clearing the promo balance before it resets costs per month. Whole
  # months only: a statement that lands after the end date is one you can't use.
  def promo_monthly_payoff(on: Date.current)
    return nil unless promo_active?(on: on) && promo_balance_money

    promo_balance_money / [ whole_months_between(on, promo_ends_on), 1 ].max
  end

  # What the promo balance accrues each month once the go-to rate applies.
  def promo_reset_monthly_interest
    return nil unless promo? && promo_balance_money && apr.present?

    promo_balance_money * apr / 100 / 12
  end

  # Deferred-interest promos bill every month of interest back to the promo
  # start if any balance survives the end date. Waived-interest promos — the
  # bank-issued kind — forgive it, so this is nil for them.
  def promo_deferred_interest_due
    return nil unless promo_deferred_interest? && promo_starts_on.present?
    return nil unless promo_ends_on && promo_starts_on <= promo_ends_on

    monthly = promo_reset_monthly_interest
    monthly && monthly * whole_months_between(promo_starts_on, promo_ends_on)
  end

  private
    def whole_months_between(from, to)
      months = (to.year * 12 + to.month) - (from.year * 12 + from.month)
      to.day < from.day ? months - 1 : months
    end
end
