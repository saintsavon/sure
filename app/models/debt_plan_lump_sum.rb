class DebtPlanLumpSum < ApplicationRecord
  belongs_to :debt_plan
  validates :expected_on, :label, presence: true
  validates :amount, numericality: { greater_than: 0 }
end
