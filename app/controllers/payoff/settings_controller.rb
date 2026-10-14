class Payoff::SettingsController < ApplicationController
  before_action :require_admin!

  def update
    plan = Current.family.debt_plan or raise ActiveRecord::RecordNotFound
    attributes = params.require(:debt_plan).permit(:strategy, :high_interest_line, :monthly_surplus,
      :payday_anchor_on, :payday_cadence, :cash_float, :emergency_fund_goal_id,
      :email_notifications_enabled, :discord_notifications_enabled, :discord_webhook_url,
      cash_account_ids: []).to_h
    attributes["cash_account_ids"] = Array(attributes["cash_account_ids"]).reject(&:blank?) if attributes.key?("cash_account_ids")
    if params[:debt_plan].key?(:surplus_steps_text)
      attributes["surplus_steps"] = params[:debt_plan][:surplus_steps_text].to_s.lines.filter_map do |line|
        from, delta, label = line.strip.split(",", 3)
        { "from" => from, "delta" => delta, "label" => label.to_s } if from.present?
      end
    end
    plan.update!(attributes)
    DebtPlan::RefreshJob.perform_later(Current.family.id)
    redirect_to payoff_path, notice: t("payoffs.notices.saved")
  rescue ActiveRecord::RecordInvalid, ActionController::ParameterMissing
    redirect_to payoff_path, alert: t("payoffs.notices.invalid")
  end

  def baseline
    plan = Current.family.debt_plan or raise ActiveRecord::RecordNotFound
    plan.take_baseline!(user: Current.user)
    redirect_to payoff_path, notice: t("payoffs.notices.baseline")
  end
end
