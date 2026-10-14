class Payoff::CelebrationsController < ApplicationController
  before_action :require_admin!

  def create
    plan = Current.family.debt_plan or raise ActiveRecord::RecordNotFound
    event = plan.debt_plan_events.where(kind: "debt_defeated", celebrated_at: nil,
      account_id: Current.family.accounts.accessible_by(Current.user).select(:id)).find(params[:event_id])
    event.update!(celebrated_at: Time.current)
    head :no_content
  end
end
