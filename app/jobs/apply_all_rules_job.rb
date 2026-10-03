class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, execution_type: "manual")
    # Not find_each: it ignores ordering, and rules must run in the family's chosen order.
    family.rules.ordered.each do |rule|
      RuleJob.perform_now(rule, ignore_attribute_locks: true, execution_type: execution_type)
    end
  end
end
