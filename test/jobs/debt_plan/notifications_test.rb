require "test_helper"

class DebtPlan::NotificationsTest < ActiveJob::TestCase
  setup do
    user = users(:family_admin)
    @plan = DebtPlan.create_with_accounts!(family: user.family, user:)
    @event = @plan.debt_plan_events.create!(kind: "debt_defeated", key: "fictional-win",
      account: accounts(:credit_card), occurred_on: Date.current)
  end

  test "email sends one digest per day" do
    @plan.update!(email_notifications_enabled: true)
    ActionMailer::Base.deliveries.clear

    2.times { DebtPlan::EmailNotifyJob.perform_now(@plan.id) }

    assert_equal 1, ActionMailer::Base.deliveries.size
    assert @event.reload.email_notified_at
    assert_equal Date.current, @plan.reload.email_digest_sent_on
  end

  test "Discord sends a short digest once and records delivery" do
    @plan.update!(discord_notifications_enabled: true,
      discord_webhook_url: "https://discord.com/api/webhooks/123/fictional-token")
    stub = stub_request(:post, @plan.discord_webhook_url).to_return(status: 204)

    2.times { DebtPlan::DiscordNotifyJob.perform_now(@plan.id) }

    assert_requested stub, times: 1
    assert @event.reload.discord_notified_at
    assert_equal Date.current, @plan.reload.discord_digest_sent_on
  end

  test "notification copy masks long account numbers" do
    accounts(:credit_card).update!(name: "Fictional Card 123456789")

    assert_includes @event.description, "••••6789"
    assert_not_includes @event.description, "123456789"
  end
end
