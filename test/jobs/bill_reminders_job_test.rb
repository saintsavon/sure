require "test_helper"

class BillRemindersJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
    @account = accounts(:depository)
    @merchant = merchants(:netflix)
  end

  test "emails an opted-in family when a bill is due soon" do
    @family.update!(bill_reminders_enabled: true, bill_reminder_days_before: 3)
    create_bill(next_expected_date: 1.day.from_now.to_date, amount: 50)

    assert_enqueued_emails 1 do
      BillRemindersJob.perform_now
    end
  end

  test "does not email when reminders are disabled" do
    @family.update!(bill_reminders_enabled: false)
    create_bill(next_expected_date: 1.day.from_now.to_date, amount: 50)

    assert_no_enqueued_emails do
      BillRemindersJob.perform_now
    end
  end

  test "does not email when nothing is overdue or due soon" do
    @family.update!(bill_reminders_enabled: true, bill_reminder_days_before: 3)
    create_bill(next_expected_date: 40.days.from_now.to_date, amount: 50) # upcoming only

    assert_no_enqueued_emails do
      BillRemindersJob.perform_now
    end
  end

  private
    def create_bill(next_expected_date:, amount:, status: "active")
      @family.recurring_transactions.create!(
        account: @account,
        merchant: @merchant,
        amount: amount,
        currency: "USD",
        expected_day_of_month: next_expected_date.day,
        last_occurrence_date: next_expected_date - 1.month,
        next_expected_date: next_expected_date,
        status: status
      )
    end
end
