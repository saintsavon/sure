class PayoffsController < ApplicationController
  before_action :require_admin!, only: :create

  def show
    @plan = Current.family.debt_plan
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.plan"), plan_path ], [ t("payoffs.show.title"), nil ] ]
    @foreign_liability_count = Current.family.accounts.accessible_by(Current.user).visible.liabilities
      .where.not(currency: Current.family.primary_currency_code).count
    return unless @plan

    @entries = @plan.visible_entries(Current.user).to_a
    @tracked_entries = @entries.reject { |entry| entry.role == "excluded" }
    @projection = @plan.project(user: Current.user)
    @alternatives = if Current.user.admin?
      %w[snowball avalanche].index_with { |strategy| @plan.project(user: Current.user, strategy:) }
    else
      {}
    end
    @tracker = DebtPlan::Tracker.new(@plan, user: Current.user)
    @next_move = DebtPlan::NextMove.new(@plan, user: Current.user)
    @minimum_projection = @plan.project(user: Current.user, surplus: 0, steps: [], lumps: [])
    @interest_avoided = [ @minimum_projection.total_interest - @projection.total_interest, 0 ].max
    @line_summary = @entries.map do |entry|
      indexes = @projection.lines.each_index.select { |index| @projection.lines[index][:entry_id] == entry.id }
      months = indexes.map { |index| @projection.payoff_month(index) }
      [ entry.id, { indexes:, payoff_month: months.all? ? months.max : nil,
                    rank: indexes.map { |index| @projection.rows.first.rank[index] }.min || 999 } ]
    end.to_h
    @current_target_line = @projection.lines.each_with_index
      .select { |line, index| line[:account_id] && line[:balance].to_f.positive? && @projection.rows.first.rank[index] < 999 }
      .min_by { |_, index| @projection.rows.first.rank[index] }&.first
    @paid_off = @tracked_entries.select { |entry| entry.starting_balance.to_d.positive? && entry.account.balance.to_d <= 0.005 }
    @active_entries = @tracked_entries - @paid_off
    @payoff_dates = @plan.debt_plan_events.where(kind: "debt_defeated", account_id: @paid_off.map(&:account_id))
      .pluck(:account_id, :occurred_on).to_h
    @last_balance_dates = Balance.where(account_id: @entries.map(&:account_id)).group(:account_id).maximum(:date)
    @writable_account_ids = Current.family.accounts.writable_by(Current.user).pluck(:id).to_set
    @timeline = @projection.rows.map do |row|
      { date: (Date.current.beginning_of_month >> row.month).iso8601,
        balances: row.end_balance.each_with_index.filter_map { |balance, index| balance unless @projection.lines[index][:savings_goal] } }
    end
    accessible_ids = Current.family.accounts.accessible_by(Current.user).pluck(:id)
    @actual_timeline = @plan.debt_plan_snapshots.order(:taken_on).last(120).map do |snapshot|
      visible_total = Array(snapshot.payload["balances"]).sum do |account_id, balance|
        accessible_ids.include?(account_id) ? balance.to_f : 0.0
      end
      { date: snapshot.taken_on.iso8601, balance: visible_total }
    end
    event_scope = @plan.debt_plan_events.where(account_id: accessible_ids)
    event_scope = event_scope.or(@plan.debt_plan_events.where(account_id: nil)) if @entries.size == @plan.debt_plan_entries.count
    @events = event_scope.order(occurred_on: :desc).limit(12)
    @uncelebrated = if Current.user.admin?
      @plan.debt_plan_events.where(kind: "debt_defeated", celebrated_at: nil, account_id: @paid_off.map(&:account_id)).to_a
    else
      []
    end
    @available_accounts = Current.family.accounts.accessible_by(Current.user).visible.liabilities
      .where(currency: Current.family.primary_currency_code)
      .where.not(id: @entries.map(&:account_id)).order(:name)
    @cash_accounts = Current.family.accounts.accessible_by(Current.user).visible.assets.where(accountable_type: "Depository")
      .where(currency: Current.family.primary_currency_code).order(:name)
    @goals = Current.family.goals.where(currency: Current.family.primary_currency_code).order(:name)
  end

  def create
    plan = Current.family.debt_plan || DebtPlan.create_with_accounts!(family: Current.family, user: Current.user)
    DebtPlan::RefreshJob.perform_later(Current.family.id)
    redirect_to payoff_path, notice: t("payoffs.notices.created")
  end
end
