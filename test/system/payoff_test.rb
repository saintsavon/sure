require "application_system_test_case"

class PayoffTest < ApplicationSystemTestCase
  test "admin sets up a payoff plan and adjusts its strategy" do
    sign_in users(:family_admin)
    visit payoff_path

    assert_text I18n.t("payoffs.show.empty_title")
    click_button I18n.t("payoffs.show.set_up")

    assert_text I18n.t("payoffs.show.payoff_order")
    assert_selector "[data-controller='payoff-timeline-chart'] svg"

    click_button I18n.t("payoffs.settings.open")
    within "#payoff-settings" do
      select I18n.t("payoffs.settings.avalanche"), from: I18n.t("payoffs.settings.strategy")
      fill_in I18n.t("payoffs.settings.monthly_surplus"), with: "500"
      click_button I18n.t("payoffs.settings.save")
    end

    assert_text I18n.t("payoffs.notices.saved")
    assert_equal "avalanche", users(:family_admin).family.debt_plan.reload.strategy
  end
end
