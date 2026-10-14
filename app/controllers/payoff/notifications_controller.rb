class Payoff::NotificationsController < ApplicationController
  before_action :require_admin!

  def test_discord
    plan = Current.family.debt_plan or raise ActiveRecord::RecordNotFound
    if plan.discord_notifications_enabled? && plan.discord_webhook_url.present?
      DebtPlan::DiscordNotifyJob.perform_later(plan.id, test_message: true)
      redirect_to payoff_path, notice: t("payoffs.notices.discord_test")
    else
      redirect_to payoff_path, alert: t("payoffs.notices.discord_missing")
    end
  end
end
