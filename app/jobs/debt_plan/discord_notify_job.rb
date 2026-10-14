require "net/http"

class DebtPlan::DiscordNotifyJob < ApplicationJob
  DeliveryError = Class.new(StandardError)

  queue_as :default
  retry_on DeliveryError, Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 4

  def perform(plan_id, test_message: false)
    plan = DebtPlan.find_by(id: plan_id)
    return unless plan&.active? && plan.discord_notifications_enabled? && plan.discord_webhook_url.present?

    plan.with_lock do
      next if !test_message && plan.discord_digest_sent_on == Date.current
      events = test_message ? [] : plan.debt_plan_events.where(discord_notified_at: nil).order(:created_at).to_a
      next if events.empty? && !test_message

      content = test_message ? I18n.t("payoffs.notifications.test_message") : events.map(&:description).join("\n")
      uri = URI.parse(plan.discord_webhook_url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) do |http|
        request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
        request.body = { content: content.first(1900) }.to_json
        http.request(request)
      end
      raise DeliveryError, "Discord returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      if events.any?
        plan.debt_plan_events.where(id: events.map(&:id)).update_all(discord_notified_at: Time.current)
        plan.update!(discord_digest_sent_on: Date.current)
      end
    end
  rescue => error
    DebugLogEntry.capture(category: "debt_plan", level: "error", message: "Discord payoff notification failed",
      source: self.class.name, provider_key: "discord", family: plan&.family,
      metadata: { error: error.class.name, detail: error.message })
    raise if error.is_a?(DeliveryError) || error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
  end
end
