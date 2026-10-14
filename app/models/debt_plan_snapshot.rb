class DebtPlanSnapshot < ApplicationRecord
  belongs_to :debt_plan
  validates :taken_on, :total_debt, presence: true
end
