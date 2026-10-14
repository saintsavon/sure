require "test_helper"

class DebtPlan::RefreshJobTest < ActiveJob::TestCase
  test "refresh records one daily snapshot and one paid-off event" do
    user = users(:family_admin)
    plan = DebtPlan.create_with_accounts!(family: user.family, user:)
    accounts(:other_liability).update!(balance: 0)

    2.times { DebtPlan::RefreshJob.perform_now(user.family_id) }

    assert_equal 1, plan.debt_plan_snapshots.where(taken_on: Date.current).count
    assert_equal 1, plan.debt_plan_events.where(key: "debt_defeated:#{accounts(:other_liability).id}").count
  end
end
