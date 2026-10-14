require "test_helper"

class PayoffsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    sign_in @admin
    ensure_tailwind_build
  end

  test "admin creates a plan and sees a projection" do
    get payoff_url
    assert_response :success
    assert_match I18n.t("payoffs.show.empty_title"), response.body

    post payoff_url
    assert_redirected_to payoff_path
    assert_equal 3, @admin.family.debt_plan.debt_plan_entries.count

    get payoff_url
    assert_response :success
    assert_match I18n.t("payoffs.show.payoff_order"), response.body
    assert_match accounts(:credit_card).name, response.body
  end

  test "member can view but cannot create or edit" do
    post payoff_url
    plan = @admin.family.debt_plan
    plan.debt_plan_snapshots.create!(taken_on: Date.current, total_debt: 1000,
      projected_total_interest: 0, payload: { balances: [ [ accounts(:loan).id, 1000 ] ] })
    plan.debt_plan_events.create!(kind: "milestone", key: "milestone:50", occurred_on: Date.current,
      payload: { percent: 50 })
    event = plan.debt_plan_events.create!(kind: "debt_defeated", key: "fictional-celebration",
      account: accounts(:credit_card), occurred_on: Date.current)
    sign_in @member

    get payoff_url
    assert_response :success
    assert_select "form[action=?]", settings_payoff_path, count: 0
    assert_select "main h3", text: accounts(:loan).name, count: 0
    chart = Nokogiri::HTML(response.body).at_css("[data-payoff-timeline-chart-actual-value]")
    assert_equal 0, JSON.parse(chart["data-payoff-timeline-chart-actual-value"]).first.fetch("balance")
    assert_no_match "50% of starting debt repaid", Nokogiri::HTML(response.body).at_css("main").text

    patch settings_payoff_url, params: { debt_plan: { monthly_surplus: 500 } }
    assert_redirected_to accounts_path
    assert_equal 0, @admin.family.debt_plan.monthly_surplus

    post celebrate_payoff_url(event_id: event.id)
    assert_redirected_to accounts_path
    assert_nil event.reload.celebrated_at
  end

  test "settings and one-time cash update the projection" do
    post payoff_url
    patch settings_payoff_url, params: { debt_plan: { monthly_surplus: 800, strategy: "avalanche" } }
    assert_redirected_to payoff_path
    assert_equal "avalanche", @admin.family.debt_plan.reload.strategy

    post payoff_lump_sums_url, params: { debt_plan_lump_sum: { expected_on: Date.current, amount: 1000, label: "Fictional bonus" } }
    assert_redirected_to payoff_path
    assert_equal 1, @admin.family.debt_plan.debt_plan_lump_sums.count
    lump = @admin.family.debt_plan.debt_plan_lump_sums.first
    patch payoff_lump_sum_url(lump), params: { debt_plan_lump_sum: { amount: 750, received_on: Date.current } }
    assert_redirected_to payoff_path
    assert_equal 750, lump.reload.amount
    assert_equal Date.current, lump.received_on
  end

  test "active promotional balance appears in the radar" do
    post payoff_url
    credit_cards(:one).update!(promo_apr: 0, promo_balance: 600,
      promo_starts_on: Date.current - 1.month, promo_ends_on: Date.current + 4.months)

    get payoff_url

    assert_response :success
    assert_match I18n.t("payoffs.show.promo_radar"), response.body
    assert_match I18n.t("payoffs.show.promo_balance_note"), response.body
  end

  test "interest avoided includes future surplus increases" do
    post payoff_url
    plan = @admin.family.debt_plan
    plan.debt_plan_entries.where.not(account: accounts(:credit_card)).update_all(role: "excluded")
    plan.update!(monthly_surplus: 0,
      surplus_steps: [ { "from" => Date.current.next_month.strftime("%Y-%m"), "delta" => 200 } ])

    get payoff_url

    assert_response :success
    text = Nokogiri::HTML(response.body).at_css("main").text
    assert_match(/\$[1-9]\d*(?:\.\d{2})? less estimated interest over 10 years than minimums alone/, text)
  end
end
