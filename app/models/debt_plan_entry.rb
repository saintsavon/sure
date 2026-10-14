class DebtPlanEntry < ApplicationRecord
  ROLES = %w[snowball minimum_only scheduled excluded].freeze

  belongs_to :debt_plan
  belongs_to :account

  validates :role, inclusion: { in: ROLES }
  validates :payment_due_day, numericality: { only_integer: true, in: 1..31 }, allow_nil: true
  validates :minimum_payment_override, :scheduled_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :account_eligible

  def minimum_payment
    return minimum_payment_override if minimum_payment_override.present?
    return account.accountable.minimum_payment if account.accountable.is_a?(CreditCard)
    return account.accountable.monthly_payment.amount if account.accountable.is_a?(Loan) && account.accountable.monthly_payment

    0
  end

  def apr
    case account.accountable
    when CreditCard then account.accountable.apr
    when Loan then account.accountable.interest_rate
    else 0
    end
  end

  private
    def account_eligible
      return if account && debt_plan && account.family_id == debt_plan.family_id && account.liability?

      errors.add(:account, :invalid)
    end
end
