class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  # Not named Period — that constant is the app-wide date range class.
  ScheduledPayment = Data.define(:period, :date, :principal, :interest, :balance) do
    def payment = principal + interest
  end

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  # Whether this loan has the fixed terms an amortization needs.
  def amortizable?
    rate_type == "fixed" && interest_rate.present? && term_months.to_i.positive?
  end

  def monthly_payment
    return nil unless amortizable?

    money(exact_monthly_payment.round)
  end

  # One row per scheduled payment, origination through final period. Empty
  # without an opening valuation: #original_balance would otherwise fall back
  # to the current balance and produce a plausible but wrong schedule.
  def amortization_schedule
    @amortization_schedule ||= build_amortization_schedule
  end

  def payoff_date
    return nil unless amortizable? && origination_date

    origination_date >> term_months
  end

  def total_interest
    return nil unless amortizable?

    amortization_schedule.sum(money(0), &:interest)
  end

  # How many scheduled payments have come due.
  def payments_made
    amortization_schedule.count { |period| period.date <= Date.current }
  end

  # Per-period principal/interest split, for the chart.
  def amortization_split_payload
    amortization_schedule.map do |period|
      {
        date: period.date.iso8601,
        principal: period.principal.amount,
        interest: period.interest.amount
      }
    end
  end

  # When principal first exceeds interest in a single payment.
  def interest_crossover_date
    amortization_schedule
      .find { |period| period.principal.amount > period.interest.amount }
      &.date
  end

  def original_balance
    @original_balance ||= account.first_valuation_amount
  end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end

  private
    def build_amortization_schedule
      return [] unless amortizable? && origination_date
      return [] if original_balance.amount.zero?

      balance = original_balance.amount.to_d
      monthly_rate = (interest_rate / 100.0 / 12.0).to_d
      # Unrounded: #monthly_payment rounds for display, and compounding that
      # over the term leaves the balance short of zero.
      payment = exact_monthly_payment.to_d

      (1..term_months).map do |n|
        interest = (balance * monthly_rate).round(2)
        principal = (payment - interest).round(2)
        # Final period (or any overshoot) clears the balance exactly.
        principal = balance if n == term_months || principal > balance
        balance = (balance - principal).round(2)

        ScheduledPayment.new(
          period: n,
          # Advanced from the anchor, not accumulated, so month-end dates
          # don't drift (Jan 31 -> Feb 28 -> Mar 31).
          date: origination_date >> n,
          principal: money(principal),
          interest: money(interest),
          balance: money(balance)
        )
      end
    end

    def exact_monthly_payment
      monthly_rate = interest_rate / 100.0 / 12.0
      principal = original_balance.amount

      # 0% loans reach here; the general formula divides by zero.
      return principal / term_months if monthly_rate.zero?

      (principal * monthly_rate * (1 + monthly_rate)**term_months) /
        ((1 + monthly_rate)**term_months - 1)
    end

    # The opening valuation is origination. defined? so a nil doesn't re-query.
    def origination_date
      return @origination_date if defined?(@origination_date)

      @origination_date = account.first_valuation&.date
    end

    def money(amount)
      Money.new(amount, account.currency)
    end
end
