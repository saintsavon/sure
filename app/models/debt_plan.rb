class DebtPlan < ApplicationRecord
  belongs_to :family
  belongs_to :emergency_fund_goal, class_name: "Goal", optional: true
  has_many :debt_plan_entries, dependent: :destroy
  has_many :debt_plan_lump_sums, dependent: :destroy
  has_many :debt_plan_events, dependent: :destroy
  has_many :debt_plan_snapshots, dependent: :destroy

  encrypts :discord_webhook_url

  validates :strategy, inclusion: { in: %w[snowball avalanche] }
  validates :state, inclusion: { in: %w[active archived] }
  validates :payday_cadence, inclusion: { in: %w[weekly biweekly semimonthly monthly] }
  validates :high_interest_line, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :cash_float, numericality: { greater_than_or_equal_to: 0 }
  validate :same_family_references
  validate :valid_webhook_url
  validate :valid_surplus_steps
  validate :semimonthly_anchor_day

  scope :active, -> { where(state: "active") }

  def active? = state == "active"

  def self.create_with_accounts!(family:, user:)
    transaction do
      plan = create!(family: family)
      family.accounts.accessible_by(user).visible.liabilities.where(currency: family.primary_currency_code).find_each do |account|
        plan.debt_plan_entries.create!(account: account, starting_balance: [ account.balance.to_d, 0 ].max)
      end
      plan.take_baseline!
      plan
    end
  end

  def visible_entries(user)
    debt_plan_entries.joins(:account)
      .where(account_id: family.accounts.accessible_by(user).visible.liabilities.select(:id))
      .includes(account: :accountable).order(:created_at, :id)
  end

  def lines(user:, on: Date.current)
    result = visible_entries(user).flat_map do |entry|
      account = entry.account
      next [] unless account.currency == family.primary_currency_code

      owed = [ account.balance.to_f, 0.0 ].max
      accountable = account.accountable
      minimum = entry.minimum_payment.to_f
      apr = entry.apr.to_f / 100
      common = { account_id: account.id, entry_id: entry.id, role: entry.role,
                 priority: entry.priority, scheduled_amount: entry.scheduled_amount.to_f,
                 savings_goal: false, include: entry.role != "excluded" }

      if accountable.is_a?(CreditCard) && accountable.promo_active?(on: on) && accountable.promo_balance.to_f.positive?
        promo = [ accountable.promo_balance.to_f, owed ].min
        standard = owed - promo
        standard_min = [ minimum, standard ].min
        last_month = (accountable.promo_ends_on.year - on.year) * 12 + accountable.promo_ends_on.month - on.month + 1
        [
          common.merge(name: account.name, balance: standard, apr: apr, minimum: standard_min),
          common.merge(name: account.name, balance: promo, apr: accountable.promo_apr.to_f / 100,
                       minimum: minimum - standard_min, promo_last_month: last_month,
                       post_promo_apr: apr, promo_ends_on: accountable.promo_ends_on, promo: true)
        ]
      else
        [ common.merge(name: account.name, balance: owed, apr: apr, minimum: minimum) ]
      end
    end

    if emergency_fund_goal && emergency_fund_goal.currency == family.primary_currency_code
      gap = [ emergency_fund_goal.target_amount.to_f - emergency_fund_goal.current_balance.amount.to_f, 0.0 ].max
      result << { name: emergency_fund_goal.name, balance: gap, apr: 0.2, minimum: 0,
                  role: "snowball", savings_goal: true, include: true }
    end
    result
  end

  def project(user:, on: Date.current, strategy: self.strategy, surplus: monthly_surplus, lumps: debt_plan_lump_sums.to_a)
    months = 120
    first_month = on.beginning_of_month
    base = Array.new(months) do |index|
      month = first_month >> index
      surplus.to_f + surplus_steps.sum { |step| step["from"].to_s <= month.strftime("%Y-%m") ? step["delta"].to_f : 0 }
    end
    lump_by_month = Hash.new(0.0)
    scheduled_months = []
    lumps.each do |lump|
      next if lump.received_on.present?

      index = (lump.expected_on.year - on.year) * 12 + lump.expected_on.month - on.month + 1
      next unless index.between?(1, months)

      lump_by_month[index] += lump.amount.to_f
      scheduled_months << index if lump.scheduled_payments?
    end
    DebtPlan::Projector.new(lines: lines(user:, on:), strategy:, high_interest_line:,
                            base_surplus: base, lumps: lump_by_month,
                            scheduled_months: scheduled_months.uniq, months:)
  end

  def take_baseline!(user: family.users.where(role: %w[admin super_admin]).first)
    return unless user

    projection = project(user:)
    update!(baseline_schedule: [ total_owed(user:) ] + projection.debt_balance_by_month,
            baseline_taken_on: Date.current)
  end

  def total_owed(user:)
    visible_entries(user).reject { |entry| entry.role == "excluded" }.sum { |entry| [ entry.account.balance.to_d, 0 ].max }
  end

  private
    def same_family_references
      if emergency_fund_goal && (emergency_fund_goal.family_id != family_id || emergency_fund_goal.currency != family.primary_currency_code)
        errors.add(:emergency_fund_goal, :invalid)
      end
      return if cash_account_ids.blank?

      valid_ids = family.accounts.assets.visible.where(accountable_type: "Depository", id: cash_account_ids, currency: family.primary_currency_code).pluck(:id)
      errors.add(:cash_account_ids, :invalid) unless valid_ids.sort == cash_account_ids.sort
    end

    def valid_webhook_url
      return if discord_webhook_url.blank?

      uri = URI.parse(discord_webhook_url)
      allowed = %w[discord.com discordapp.com].include?(uri.host) && uri.scheme == "https" && uri.port == 443 &&
        uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.path.match?(%r{\A/api/webhooks/\d+/[^/]+\z})
      errors.add(:discord_webhook_url, :invalid) unless allowed
    rescue URI::InvalidURIError
      errors.add(:discord_webhook_url, :invalid)
    end

    def valid_surplus_steps
      return errors.add(:surplus_steps, :invalid) unless surplus_steps.is_a?(Array)

      surplus_steps.each do |step|
        next if step.is_a?(Hash) && step["from"].to_s.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/) && Float(step["delta"], exception: false)

        errors.add(:surplus_steps, :invalid)
        break
      end
    end

    def semimonthly_anchor_day
      if payday_cadence == "semimonthly" && payday_anchor_on && payday_anchor_on.day > 16
        errors.add(:payday_anchor_on, :invalid)
      end
    end
end
