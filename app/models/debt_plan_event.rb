class DebtPlanEvent < ApplicationRecord
  belongs_to :debt_plan
  belongs_to :account, optional: true
  validates :kind, :key, :occurred_on, presence: true

  def description
    suffix = kind == "streak" ? ".#{payload['type']}" : ""
    safe_name = account&.name.to_s.gsub(/\d{5,}/) { |digits| "••••#{digits.last(4)}" }
    safe_name = I18n.t("payoffs.notifications.your_plan") if safe_name.blank?
    I18n.t("payoffs.notifications.#{kind}#{suffix}", name: safe_name,
      percent: payload["percent"], count: payload["count"], default: kind.humanize)
  end
end
