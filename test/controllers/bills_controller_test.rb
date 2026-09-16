require "test_helper"

class BillsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
    @account = accounts(:depository)
    @merchant = merchants(:netflix)
  end

  test "index renders bills grouped by status" do
    create_bill(next_expected_date: 5.days.ago.to_date, amount: 50)      # overdue
    create_bill(next_expected_date: 2.days.from_now.to_date, amount: 60) # due soon (default 3-day window)
    create_bill(next_expected_date: 40.days.from_now.to_date, amount: 70) # upcoming

    get bills_path

    assert_response :success
    assert_select "h1", text: I18n.t("bills.index.title")
  end

  test "index renders the empty state when there are no bills" do
    get bills_path

    assert_response :success
  end

  test "mark_paid advances the bill and redirects" do
    bill = create_bill(next_expected_date: 2.days.ago.to_date, amount: 50)

    post mark_paid_bill_path(bill)

    assert_redirected_to bills_path
    assert_equal Date.current, bill.reload.last_occurrence_date
  end

  test "update_settings persists reminder preferences" do
    patch update_settings_bills_path, params: {
      family: { bill_reminders_enabled: true, bill_reminder_days_before: 7 }
    }

    assert_redirected_to bills_path
    @family.reload
    assert @family.bill_reminders_enabled?
    assert_equal 7, @family.bill_reminder_days_before
  end

  test "update_settings rejects an out-of-range reminder window" do
    patch update_settings_bills_path, params: {
      family: { bill_reminders_enabled: true, bill_reminder_days_before: -5 }
    }

    assert_redirected_to bills_path
    @family.reload
    refute @family.bill_reminders_enabled?, "invalid update must roll back atomically"
    assert_equal 3, @family.bill_reminder_days_before
  end

  test "mark_paid returns not found for a non-bill (income) row" do
    income = @family.recurring_transactions.create!(
      account: @account, merchant: @merchant, amount: -1000, currency: "USD",
      expected_day_of_month: 1, last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 2.days.ago.to_date, status: "active"
    )

    post mark_paid_bill_path(income)

    assert_response :not_found
    assert_equal 0, income.reload.occurrence_count
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
