class BudgetCategoriesController < ApplicationController
  InvalidMove = Class.new(StandardError)

  before_action :set_budget

  def index
    @budget_categories = @budget.budget_categories.includes(:category)
    render layout: "wizard"
  end

  def show
    # The aggregate `Budget#actual_spending` already excludes transactions
    # whose kind is in BUDGET_EXCLUDED_KINDS (funds_movement, one_time,
    # cc_payment) via IncomeStatement. The drilldown list must apply the
    # same filter, otherwise a matched transfer (post-#874 the matcher
    # correctly tags inflow as funds_movement and outflow per destination
    # account) shows under the Uncategorized card -- or any retained
    # category -- even though the aggregate ignores it. See issue #1059.
    @recent_transactions = @budget.transactions
                                  .where.not(transactions: { kind: Transaction::BUDGET_EXCLUDED_KINDS })

    if params[:id] == BudgetCategory.uncategorized.id
      @budget_category = @budget.uncategorized_budget_category
      @recent_transactions = @recent_transactions.where(transactions: { category_id: nil })
    else
      @budget_category = Current.family.budget_categories.find(params[:id])
      @recent_transactions = @recent_transactions.joins("LEFT JOIN categories ON categories.id = transactions.category_id")
                                                 .where("categories.id = ? OR categories.parent_id = ?", @budget_category.category.id, @budget_category.category.id)
    end

    @recent_transactions = @recent_transactions.order("entries.date DESC, ABS(entries.amount) DESC").take(3)
  end

  def update
    @budget_category = Current.family.budget_categories.find(params[:id])
    @budget_category.update_budgeted_spending!(budgeted_spending_param)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget) }
    end
  rescue ActiveRecord::RecordInvalid
    render :index, status: :unprocessable_entity
  end

  # "Move money" between two categories in the same budget, e.g. to cover an
  # over-budget category from one with room to spare. Transfer the current
  # month's allocation first, then any carried funds that remain.
  def move
    unless Current.family.budget_rollover_enabled?
      redirect_to budget_budget_categories_path(@budget), alert: t(".invalid")
      return
    end

    @source = movable_budget_categories.find_by(id: move_params[:source_id])
    @destination = movable_budget_categories.find_by(id: move_params[:destination_id])
    amount = move_params[:amount].presence&.to_d || 0

    BudgetCategory.transaction do
      if @source && @destination
        BudgetCategory.where(id: [ @source.id, @destination.id ]).order(:id).lock.load
        @source.reload
        @destination.reload
      end
      raise InvalidMove if invalid_move?(amount)

      budgeted_part = [ amount, [ (@source.budgeted_spending || 0), 0 ].max ].min
      rollover_part = amount - budgeted_part

      if budgeted_part.positive?
        @source.update_budgeted_spending!(@source.budgeted_spending - budgeted_part)
        @destination.update_budgeted_spending!((@destination.budgeted_spending || 0) + budgeted_part)
      end

      if rollover_part.positive?
        @source.update!(
          rollover_adjustment: @source.rollover_adjustment - rollover_part,
          rollover_amount: @source.rollover_amount - rollover_part
        )
        @destination.update!(
          rollover_adjustment: @destination.rollover_adjustment + rollover_part,
          rollover_amount: @destination.rollover_amount + rollover_part
        )
      end
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget), notice: t(".success") }
    end
  rescue ActiveRecord::RecordInvalid, InvalidMove
    # update_budgeted_spending! can raise if a concurrent edit leaves a parent
    # below its subcategory total; surface the friendly alert instead of a 500,
    # mirroring #update.
    redirect_to budget_budget_categories_path(@budget), alert: t(".invalid")
  end

  private
    def movable_budget_categories
      Current.family.budget_categories.where(budget_id: @budget.id)
    end

    def move_params
      params.permit(:source_id, :destination_id, :amount)
    end

    def invalid_move?(amount)
      return true if @source.blank? || @destination.blank?
      return true if @source.id == @destination.id
      return true if amount <= 0
      return true if @source.inherits_parent_budget?
      return true if amount > @source.available_to_spend

      # Covering an inheriting subcategory would silently convert it into an
      # individually-budgeted one and inflate its parent's total -- it shares
      # the parent's pool and has no envelope of its own to fund.
      return true if @destination.inherits_parent_budget?

      # A move between a category and its own parent/subcategory can't be done
      # as two independent allocation edits: update_budgeted_spending!'s
      # parent<->child sync makes the second write read stale or clobber the
      # first. Sibling and unrelated moves are unaffected.
      return true if parent_child_pair?(@source, @destination)

      false
    end

    def parent_child_pair?(a, b)
      a.category.parent_id == b.category_id || b.category.parent_id == a.category_id
    end

    def budgeted_spending_param
      params.require(:budget_category)
        .permit(:budgeted_spending)
        .fetch(:budgeted_spending, nil)
        .presence || 0
    end

    def set_budget
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      @budget = Current.family.budgets.find_by!(start_date: start_date)
    end
end
