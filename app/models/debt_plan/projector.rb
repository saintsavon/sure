class DebtPlan::Projector
  BIG = 9e9
  Row = Data.define(:month, :start, :apr, :interest, :minimum, :extra, :end_balance, :pool, :rank)

  attr_reader :lines, :rows

  def initialize(lines:, strategy:, high_interest_line:, base_surplus:, lumps: {}, scheduled_months: [], scheduled_amount: 0, months: 120)
    @lines = lines.map { |line| line.transform_keys(&:to_sym) }
    @strategy = strategy
    @high_interest_line = high_interest_line.to_f
    @base_surplus = base_surplus
    @lumps = lumps.transform_keys(&:to_i)
    @scheduled_months = scheduled_months
    @scheduled_amount = scheduled_amount.to_f
    @months = months
    @rows = build_rows.freeze
  end

  def payoff_month(index)
    return 0 if rows.first.nil? || rows.first.start[index] <= 0.005

    rows.find { |row| row.end_balance[index] <= 0.005 }&.month
  end

  def debt_free_month
    debt_indexes = lines.each_index.reject { |index| lines[index][:savings_goal] || !included?(lines[index]) }
    debt_indexes.map { |index| payoff_month(index) }.compact.max if debt_indexes.all? { |index| payoff_month(index) }
  end

  def total_interest(months = @months)
    rows.first(months).sum { |row| row.interest.each_with_index.sum { |interest, index| lines[index][:savings_goal] ? 0 : interest } }
  end

  def total_balance_by_month
    rows.map { |row| row.end_balance.sum }
  end

  def debt_balance_by_month
    rows.map { |row| row.end_balance.each_with_index.sum { |balance, index| lines[index][:savings_goal] ? 0 : balance } }
  end

  private
    def included?(line)
      line.fetch(:include, true) && line[:role] != "excluded"
    end

    def build_rows
      balances = lines.map { |line| included?(line) ? [ line[:balance].to_f, 0 ].max : 0.0 }
      listed_minimum = lines.sum { |line| included?(line) ? line[:minimum].to_f : 0.0 }

      (1..@months).map do |month|
        start = balances.dup
        apr = []
        interest = []
        minimum = []
        need = []
        keys = []

        lines.each_with_index do |line, index|
          opening = start[index]
          promo_last = line[:promo_last_month].to_i
          rate = if !included?(line) || opening <= 0
            -1.0
          elsif promo_last.positive? && month > promo_last
            line[:post_promo_apr].to_f
          else
            line[:apr].to_f
          end
          apr << rate
          interest << (line[:savings_goal] ? 0.0 : opening * [ rate, 0 ].max / 12)
          minimum << if opening <= 0
            0.0
          elsif line[:role] == "scheduled"
            @scheduled_months.include?(month) ? [ opening, line.fetch(:scheduled_amount, @scheduled_amount).to_f ].min : 0.0
          else
            [ opening + interest[index], line[:minimum].to_f ].min
          end
          need << [ 0.0, opening + interest[index] - minimum[index] ].max
          keys << ranking_key(line, rate, opening, month, promo_last)
        end

        rank = lines.each_with_index.map do |line, index|
          if keys[index] >= BIG
            999
          elsif line[:priority].to_i.positive?
            -1000 + line[:priority].to_i
          else
            keys.count { |key| key < keys[index] } + keys[...index].count { |key| key == keys[index] }
          end
        end

        pool = [ 0.0, @base_surplus.fetch(month - 1, @base_surplus.last || 0).to_f + @lumps.fetch(month, 0).to_f + listed_minimum - minimum.sum ].max
        extra = lines.each_index.map do |index|
          next 0.0 if rank[index] >= 999

          ahead = lines.each_index.sum { |other| rank[other] < rank[index] ? need[other] : 0.0 }
          [ [ pool - ahead, 0.0 ].max, need[index] ].min
        end
        balances = lines.each_index.map { |index| [ 0.0, start[index] + interest[index] - minimum[index] - extra[index] ].max }
        Row.new(month:, start: start.freeze, apr: apr.freeze, interest: interest.freeze,
                minimum: minimum.freeze, extra: extra.freeze, end_balance: balances.freeze, pool:, rank: rank.freeze)
      end
    end

    def ranking_key(line, apr, opening, month, promo_last)
      return BIG if apr.negative? || %w[scheduled minimum_only excluded].include?(line[:role])
      return -apr if @strategy == "avalanche"

      tier = if line[:savings_goal]
        2
      elsif apr >= @high_interest_line || (promo_last.positive? && month >= promo_last - 1 && line[:post_promo_apr].to_f >= @high_interest_line)
        1
      else
        3
      end
      tier * 1e7 + opening
    end
end
