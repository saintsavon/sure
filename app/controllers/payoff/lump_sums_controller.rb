class Payoff::LumpSumsController < ApplicationController
  before_action :require_admin!

  def create
    Current.family.debt_plan.debt_plan_lump_sums.create!(params.require(:debt_plan_lump_sum)
      .permit(:expected_on, :amount, :label, :scheduled_payments))
    DebtPlan::RefreshJob.perform_later(Current.family.id)
    redirect_to payoff_path, notice: t("payoffs.notices.saved")
  rescue ActiveRecord::RecordInvalid, ActionController::ParameterMissing
    redirect_to payoff_path, alert: t("payoffs.notices.invalid")
  end

  def destroy
    Current.family.debt_plan.debt_plan_lump_sums.find(params[:id]).destroy!
    DebtPlan::RefreshJob.perform_later(Current.family.id)
    redirect_to payoff_path, notice: t("payoffs.notices.saved")
  end

  def update
    lump = Current.family.debt_plan.debt_plan_lump_sums.find(params[:id])
    lump.update!(params.require(:debt_plan_lump_sum)
      .permit(:expected_on, :amount, :label, :received_on, :scheduled_payments))
    DebtPlan::RefreshJob.perform_later(Current.family.id)
    redirect_to payoff_path, notice: t("payoffs.notices.saved")
  rescue ActiveRecord::RecordInvalid, ActionController::ParameterMissing
    redirect_to payoff_path, alert: t("payoffs.notices.invalid")
  end
end
