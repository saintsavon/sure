require "test_helper"

class RulesControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get new" do
    get new_rule_url(resource_type: "transaction")
    assert_response :success
  end

  test "should get new with pre-filled name and action" do
    category = categories(:food_and_drink)
    get new_rule_url(
      resource_type: "transaction",
      name: "Starbucks",
      action_type: "set_transaction_category",
      action_value: category.id
    )
    assert_response :success

    assert_select "input[name='rule[name]'][value='Starbucks']"
    assert_select "input[name*='[value]'][value='Starbucks']"
    assert_select "select[name*='[condition_type]'] option[selected][value='transaction_name']"
    assert_select "select[name*='[action_type]'] option[selected][value='set_transaction_category']"
    assert_select "select[name*='[value]'] option[selected][value='#{category.id}']"
  end

  test "should get edit" do
    get edit_rule_url(rules(:one))
    assert_response :success
  end

  # "Set all transactions with a name like 'starbucks' and an amount between 20 and 40 to the 'food and drink' category"
  test "creates rule with nested conditions" do
    post rules_url, params: {
      rule: {
        effective_date: 30.days.ago.to_date,
        resource_type: "transaction",
        conditions_attributes: {
          "0" => {
            condition_type: "transaction_name",
            operator: "like",
            value: "starbucks"
          },
          "1" => {
            condition_type: "compound",
            operator: "and",
            sub_conditions_attributes: {
              "0" => {
                condition_type: "transaction_amount",
                operator: ">",
                value: 20
              },
              "1" => {
                condition_type: "transaction_amount",
                operator: "<",
                value: 40
              }
            }
          }
        },
        actions_attributes: {
          "0" => {
            action_type: "set_transaction_category",
            value: categories(:food_and_drink).id
          }
        }
      }
    }

    rule = @user.family.rules.order("created_at DESC").first

    # Rule
    assert_equal "transaction", rule.resource_type
    assert_not rule.active # Not active by default
    assert_equal 30.days.ago.to_date, rule.effective_date

    # Conditions assertions
    assert_equal 2, rule.conditions.count
    compound_condition = rule.conditions.find { |condition| condition.condition_type == "compound" }
    assert_equal "compound", compound_condition.condition_type
    assert_equal 2, compound_condition.sub_conditions.count

    # Actions assertions
    assert_equal 1, rule.actions.count
    assert_equal "set_transaction_category", rule.actions.first.action_type
    assert_equal categories(:food_and_drink).id, rule.actions.first.value

    assert_redirected_to confirm_rule_url(rule, reload_on_close: true)
  end

  test "can update rule" do
    rule = rules(:one)

    assert_difference -> { Rule.count } => 0,
      -> { Rule::Condition.count } => 1,
      -> { Rule::Action.count } => 1 do
      patch rule_url(rule), params: {
        rule: {
          active: false,
          conditions_attributes: {
            "0" => {
              id: rule.conditions.first.id,
              value: "new_value"
            },
            "1" => {
              condition_type: "transaction_amount",
              operator: ">",
              value: 100
            }
          },
          actions_attributes: {
            "0" => {
              id: rule.actions.first.id,
              value: "new_value"
            },
            "1" => {
              action_type: "set_transaction_tags",
              value: tags(:one).id
            }
          }
        }
      }
    end

    rule.reload

    assert_not rule.active
    assert_equal "new_value", rule.conditions.order("created_at ASC").first.value
    assert_equal "new_value", rule.actions.order("created_at ASC").first.value
    assert_equal tags(:one).id, rule.actions.order("created_at ASC").last.value
    assert_equal "100", rule.conditions.order("created_at ASC").last.value

    assert_redirected_to rules_url
  end

  test "can destroy conditions and actions while editing" do
    rule = rules(:one)

    assert_equal 1, rule.conditions.count
    assert_equal 1, rule.actions.count

    patch rule_url(rule), params: {
      rule: {
        conditions_attributes: {
          "0" => { id: rule.conditions.first.id, _destroy: true },
          "1" => {
            condition_type: "transaction_name",
            operator: "like",
            value: "new_condition"
          }
        },
        actions_attributes: {
          "0" => { id: rule.actions.first.id, _destroy: true },
          "1" => {
            action_type: "set_transaction_tags",
            value: tags(:one).id
          }
        }
      }
    }

    assert_redirected_to rules_url

    rule.reload

    assert_equal 1, rule.conditions.count
    assert_equal 1, rule.actions.count
  end

  test "can destroy rule" do
    rule = rules(:one)

    assert_difference [ "Rule.count", "Rule::Condition.count", "Rule::Action.count" ], -1 do
      delete rule_url(rule)
    end

    assert_redirected_to rules_url
  end

  test "index renders when rule has empty compound condition" do
    malformed_rule = @user.family.rules.build(resource_type: "transaction")
    malformed_rule.conditions.build(condition_type: "compound", operator: "and")
    malformed_rule.actions.build(action_type: "exclude_transaction")
    malformed_rule.save!

    get rules_url

    assert_response :success
    assert_includes response.body, I18n.t("rules.no_condition")
  end

  test "index uses next valid condition when first compound condition is empty" do
    rule = @user.family.rules.build(resource_type: "transaction")
    rule.conditions.build(condition_type: "compound", operator: "and")
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "edge-case-name")
    rule.actions.build(action_type: "exclude_transaction")
    rule.save!

    get rules_url

    assert_response :success

    assert_select "##{ActionView::RecordIdentifier.dom_id(rule)}" do
      assert_select "span", text: /edge-case-name/
      assert_select "span", text: /#{Regexp.escape(I18n.t("rules.no_condition"))}/, count: 0
      assert_select "p", text: /and 1 more condition/, count: 0
    end
  end

  test "index shows blocked count in recent runs summary" do
    rule = rules(:one)
    RuleRun.create!(
      rule: rule,
      execution_type: "manual",
      status: "success",
      transactions_queued: 10,
      transactions_processed: 7,
      transactions_modified: 4,
      pending_jobs_count: 0,
      executed_at: Time.current
    )

    get rules_url

    assert_response :success
    assert_select "th", text: /Queued\s+Processed\s+Modified\s+Blocked/
    assert_select "td", text: "10 / 7 / 4 / 3"
  end

  test "should get confirm_all" do
    get confirm_all_rules_url
    assert_response :success
  end

  test "apply_all enqueues job and redirects" do
    assert_enqueued_with(job: ApplyAllRulesJob) do
      post apply_all_rules_url
    end

    assert_redirected_to rules_url
  end

  test "index lists rules in position order and shows move controls" do
    first, second = create_ordered_rules(2)
    second.move_higher!

    get rules_url

    assert_response :success

    body = response.body
    assert_operator body.index(dom_id(second)), :<, body.index(dom_id(first))

    move_up = I18n.t("rules.rule.move_up")
    move_down = I18n.t("rules.rule.move_down")

    # Top row can only move down, middle row both ways, bottom row only up
    top = "##{dom_id(rules(:one))}"
    assert_select "#{top} form[action='#{move_rule_path(rules(:one))}'] input[name='direction'][value='down']", count: 1
    assert_select "#{top} form[action='#{move_rule_path(rules(:one))}'] input[name='direction'][value='up']", count: 0
    assert_select "#{top} button[disabled][aria-label='#{move_up}']", count: 1

    middle = "##{dom_id(second)}"
    assert_select "#{middle} form[action='#{move_rule_path(second)}']", count: 2
    assert_select "#{middle} button[disabled][aria-label='#{move_up}']", count: 0
    assert_select "#{middle} button[disabled][aria-label='#{move_down}']", count: 0

    bottom = "##{dom_id(first)}"
    assert_select "#{bottom} form[action='#{move_rule_path(first)}'] input[name='direction'][value='up']", count: 1
    assert_select "#{bottom} form[action='#{move_rule_path(first)}'] input[name='direction'][value='down']", count: 0
    assert_select "#{bottom} button[disabled][aria-label='#{move_down}']", count: 1
  end

  test "index hides move controls when sorted by another column" do
    create_ordered_rules(2)

    get rules_url(sort_by: "name")

    assert_response :success
    assert_select "form[action$='/move']", count: 0
  end

  test "move up swaps a rule with the one above it" do
    first, second, third = create_ordered_rules(3)

    patch move_rule_url(second), params: { direction: "up" }

    assert_redirected_to rules_url
    assert_equal [ rules(:one), second, first, third ], @user.family.rules.ordered.to_a
    assert_equal [ 0, 1, 2, 3 ], @user.family.rules.ordered.pluck(:position)
  end

  test "move down swaps a rule with the one below it" do
    first, second, third = create_ordered_rules(3)

    patch move_rule_url(second), params: { direction: "down" }

    assert_redirected_to rules_url
    assert_equal [ rules(:one), first, third, second ], @user.family.rules.ordered.to_a
    assert_equal [ 0, 1, 2, 3 ], @user.family.rules.ordered.pluck(:position)
  end

  test "move is a no-op at the ends of the list" do
    _first, second = create_ordered_rules(2)

    assert_no_changes -> { @user.family.rules.ordered.pluck(:id, :position) } do
      patch move_rule_url(rules(:one)), params: { direction: "up" }
      patch move_rule_url(second), params: { direction: "down" }
    end

    assert_redirected_to rules_url
  end

  test "move rejects an unknown direction" do
    _first, second = create_ordered_rules(2)

    assert_no_changes -> { @user.family.rules.ordered.pluck(:id, :position) } do
      patch move_rule_url(second), params: { direction: "sideways" }
    end

    assert_redirected_to rules_url
    assert_equal I18n.t("rules.move.invalid_direction"), flash[:alert]
  end

  test "move rejects a missing direction" do
    _first, second = create_ordered_rules(2)

    assert_no_changes -> { @user.family.rules.ordered.pluck(:id, :position) } do
      patch move_rule_url(second)
    end

    assert_redirected_to rules_url
    assert_equal I18n.t("rules.move.invalid_direction"), flash[:alert]
  end

  test "move responds with a turbo_stream re-rendering the rules list" do
    first, second = create_ordered_rules(2)

    patch move_rule_url(second), params: { direction: "up" }, as: :turbo_stream

    assert_response :success
    assert_includes response.body, 'target="rules_list"'

    body = response.body
    assert_operator body.index(dom_id(second)), :<, body.index(dom_id(first))
    assert_equal [ rules(:one), second, first ], @user.family.rules.ordered.to_a
  end

  test "move cannot reorder another family's rule" do
    other_family = families(:empty)
    other_rules = 2.times.map do |i|
      other_family.rules.create!(
        name: "Other #{i}",
        resource_type: "transaction",
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
      )
    end

    assert_no_changes -> { other_family.rules.ordered.pluck(:id, :position) } do
      patch move_rule_url(other_rules.last), params: { direction: "up" }
    end

    assert_response :not_found
  end

  test "new rules are appended after existing rules" do
    existing_rule = rules(:one)

    post rules_url, params: {
      rule: {
        resource_type: "transaction",
        actions_attributes: { "0" => { action_type: "exclude_transaction" } }
      }
    }

    created_rule = @user.family.rules.ordered.last
    assert_not_equal existing_rule, created_rule
    assert_equal existing_rule.reload.position + 1, created_rule.position
  end

  private
    def create_ordered_rules(count)
      count.times.map do |i|
        @user.family.rules.create!(
          name: "Ordered rule #{i}",
          resource_type: "transaction",
          actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
        )
      end
    end
end
