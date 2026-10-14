class Payoff::EntriesController < ApplicationController
  before_action :require_admin!

  def create
    plan = Current.family.debt_plan or raise ActiveRecord::RecordNotFound
    account = Current.family.accounts.accessible_by(Current.user).visible.liabilities
      .where(currency: Current.family.primary_currency_code).find(params[:account_id])
    plan.debt_plan_entries.create!(account:, starting_balance: [ account.balance.to_d, 0 ].max)
    DebtPlan::RefreshJob.perform_later(Current.family.id)
    redirect_to payoff_path, notice: t("payoffs.notices.saved")
  rescue ActiveRecord::RecordInvalid
    redirect_to payoff_path, alert: t("payoffs.notices.invalid")
  end

  def update
    entry = Current.family.debt_plan.debt_plan_entries
      .where(account_id: Current.family.accounts.accessible_by(Current.user).select(:id)).find(params[:id])
    input = params.require(:debt_plan_entry)
    attributes = input.permit(:priority, :minimum_payment_override, :scheduled_amount,
      :payment_due_day, :frozen_card, :notes).to_h
    attributes["role"] = input[:role] if DebtPlanEntry::ROLES.include?(input[:role])
    entry.update!(attributes)
    DebtPlan::RefreshJob.perform_later(Current.family.id)
    redirect_to payoff_path, notice: t("payoffs.notices.saved")
  rescue ActiveRecord::RecordInvalid, ActionController::ParameterMissing
    redirect_to payoff_path, alert: t("payoffs.notices.invalid")
  end
end
