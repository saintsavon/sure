module PayoffsHelper
  def payoff_money(amount)
    format_money(Money.new(amount || 0, Current.family.primary_currency_code))
  end

  def payoff_month_date(month)
    return unless month
    return I18n.l(Date.current, format: "%b %Y") if month.zero?

    I18n.l(Date.current.beginning_of_month >> (month - 1), format: "%b %Y")
  end

  def payoff_progress(entry)
    return 0 if entry.starting_balance.to_d <= 0

    ((1 - [ entry.account.balance.to_d, 0 ].max / entry.starting_balance.to_d) * 100).clamp(0, 100).round
  end
end
