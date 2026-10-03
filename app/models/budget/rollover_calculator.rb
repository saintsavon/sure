# Computes and persists each of a budget's `budget_categories.rollover_amount`
# — the leftover (or zero, if overspent) money carried in from the same
# category in the prior initialized budget. `rollover_amount` is a cache: it
# is always recomputed from scratch whenever a month is opened (see
# `Budget#find_or_bootstrap`), so it stays correct even if an earlier month's
# numbers change after the fact (e.g. a re-categorized transaction).
#
# v1 policy is positive-only carry: overspending a category never creates a
# negative envelope for the next month (see `ending_balance`).
class Budget::RolloverCalculator
  # Bounds the recursive walk back through `most_recent_initialized_budget` so
  # a very old or unusual family history can't turn opening a single month
  # into an unbounded chain of recalculation. Budgets are already capped to a
  # ~2 year (24 month) window (see `Budget.oldest_valid_budget_date`), so this
  # is a belt-and-suspenders bound, not expected to bind in practice.
  MAX_CHAIN_LENGTH = 24

  def initialize(budget)
    @budget = budget
  end

  # Recomputes `rollover_amount` for every budget_category on `budget`. When
  # rollover is disabled for the family, this simply zeroes them out so a
  # stale value left over from when the setting was enabled never lingers.
  def calculate!
    if budget.family.budget_rollover_enabled?
      apply_rollover!(budget, memo: {})
    else
      zero_out!(budget)
    end

    nil
  end

  private
    attr_reader :budget

    # Ensures `target_budget`'s prior budget (if any) already has a correct,
    # persisted `rollover_amount` before computing `target_budget`'s own
    # carry-in from it. `memo` avoids recomputing the same budget twice within
    # one top-level `calculate!` call (e.g. if it appeared earlier in the
    # chain already).
    def apply_rollover!(target_budget, memo:, remaining_hops: MAX_CHAIN_LENGTH)
      return memo[target_budget.id] if memo.key?(target_budget.id)

      prior_budget = remaining_hops.positive? ? target_budget.most_recent_initialized_budget : nil

      carry_in_by_category =
        if prior_budget
          apply_rollover!(prior_budget, memo: memo, remaining_hops: remaining_hops - 1)
          ending_balances_by_category(prior_budget)
        else
          {}
        end

      persist_rollover!(target_budget, carry_in_by_category)
      memo[target_budget.id] = carry_in_by_category
    end

    # Each category's leftover = its own `available_to_spend` (which already
    # folds in that month's carried-in `rollover_amount`), clamped to zero so
    # an overspent category never carries a negative balance forward in v1.
    #
    # We deliberately reuse `available_to_spend` rather than the raw
    # `rollover + budgeted - spent` formula so ring-fenced subcategory
    # leftovers aren't double-counted: a parent's `budgeted_spending` and
    # `actual_spending` already include its children, so the parent's own
    # `available_to_spend` reports only its shared-pool leftover while each
    # ring-fenced child reports its own. An inheriting subcategory has no
    # envelope of its own (it draws from the parent's pool), so it carries
    # nothing -- its leftover already lives in the parent's balance.
    def ending_balances_by_category(prior_budget)
      prior_budget.budget_categories.each_with_object({}) do |bc, balances|
        ending_balance = bc.inherits_parent_budget? ? 0 : bc.available_to_spend
        balances[bc.category_id] = [ ending_balance, 0 ].max
      end
    end

    # `update_column` is intentional here: this is a derived cache, not a
    # user edit, so there's nothing worth validating and no reason to bump
    # `updated_at` on every budget open.
    def persist_rollover!(target_budget, carry_in_by_category)
      target_budget.budget_categories.each do |bc|
        new_amount = carry_in_by_category.fetch(bc.category_id, 0)
        bc.update_column(:rollover_amount, new_amount) unless bc.rollover_amount == new_amount
      end
    end

    def zero_out!(target_budget)
      target_budget.budget_categories.each do |bc|
        bc.update_column(:rollover_amount, 0) unless bc.rollover_amount == 0
      end
    end
end
