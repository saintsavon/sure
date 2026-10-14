class DebtPlan::DailyJob < ApplicationJob
  queue_as :scheduled

  def perform
    DebtPlan.active.find_each { |plan| DebtPlan::RefreshJob.perform_later(plan.family_id) }
  end
end
