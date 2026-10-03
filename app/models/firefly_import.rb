class FireflyImport < Import
  after_create :set_mappings

  DEFAULT_COLUMN_MAPPINGS = {
    signage_convention: "inflows_positive",
    date_col_label: "date",
    date_format: "%Y-%m-%d",
    name_col_label: "description",
    amount_col_label: "amount",
    category_col_label: "category",
    notes_col_label: "notes"
  }.freeze

  # Firefly III is double-entry: every row moves money from a source account to a
  # destination account. These literal headers drive which side is the "real"
  # (asset) account and which direction the money moved, so they aren't surfaced
  # as remappable column labels.
  TYPE_COLUMN = "type".freeze
  CURRENCY_COLUMN = "currency_code".freeze
  SOURCE_ACCOUNT_COLUMN = "source_name".freeze
  DESTINATION_ACCOUNT_COLUMN = "destination_name".freeze

  # Firefly III transaction types (the "type" column), compared case-insensitively.
  # Anything else (e.g. "Opening balance", "Reconciliation") falls back to the sign
  # of the amount to decide the direction.
  DEPOSIT_TYPE = "deposit".freeze
  WITHDRAWAL_TYPE = "withdrawal".freeze
  TRANSFER_TYPE = "transfer".freeze

  # Firefly III exports dates as ISO 8601 timestamps (e.g. "2024-01-01T00:00:00+01:00").
  # Only the calendar date is needed, so strip the time/offset to match "%Y-%m-%d".
  ISO_TIMESTAMP_DATE = /\A(\d{4}-\d{2}-\d{2})[T\s]/

  def self.default_column_mappings
    DEFAULT_COLUMN_MAPPINGS
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map.with_index(1) do |row, index|
      amount = parsed_amount(row)

      {
        source_row_number: index,
        account: account_name(row, amount),
        date: row_date(row),
        amount: directed_amount(row, amount).to_s,
        currency: (csv_value(row, currency_col_label.presence || CURRENCY_COLUMN, "currency") || default_currency).to_s,
        name: row_name(row),
        category: csv_value(row, category_col_label, "category").to_s.strip,
        notes: csv_value(row, notes_col_label, "notes").to_s
      }
    end

    rows.insert_all!(mapped_rows)
    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      rows.each do |row|
        account = mappings.accounts.mappable_for(row.account)
        category = mappings.categories.mappable_for(row.category)

        entry = account.entries.build \
          date: row.date_iso,
          amount: row.signed_amount,
          name: row.name,
          # Firefly is multi-currency; keep the row's currency (from
          # currency_code) when present so a foreign-currency row isn't
          # silently recorded in the account's currency.
          currency: row.currency.presence || account.currency.presence || family.currency,
          notes: row.notes,
          entryable: Transaction.new(category: category),
          import: self

        entry.save!
      end
    end
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::AccountMapping ]
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name category account notes]
  end

  def csv_template
    template = <<~CSV
      type,amount,currency_code,date,description,category,source_name,destination_name,notes
      Withdrawal,-8.55,USD,2024-01-01,Starbucks,Food & Drink,Checking,Starbucks,Morning coffee
      Deposit,2500.00,USD,2024-01-05,Employer,Income,Employer,Checking,Monthly salary
    CSV

    CSV.parse(template, headers: true)
  end

  private
    def set_mappings
      assign_attributes(self.class.default_column_mappings)
      save!
    end

    # nil when the amount is missing or isn't a number, so callers can tell a blank
    # amount apart from a genuine zero.
    def parsed_amount(row)
      raw = csv_value(row, amount_col_label.presence || "amount")
      return nil if raw.blank?

      sanitized = sanitize_number(raw)
      return nil if sanitized.blank?

      sanitized.to_d
    end

    def directed_amount(row, amount)
      return nil if amount.nil?

      magnitude = amount.abs

      case transaction_type(row)
      when DEPOSIT_TYPE then magnitude
      # 0 - x rather than -x, so a zero amount stays "0.0" instead of becoming "-0.0".
      when WITHDRAWAL_TYPE, TRANSFER_TYPE then BigDecimal("0") - magnitude
      else amount
      end
    end

    def transaction_type(row)
      csv_value(row, TYPE_COLUMN).to_s.strip.downcase
    end

    # Firefly rows have a source and a destination. For a withdrawal the other
    # side is an expense account (e.g. a store) and for a deposit it's a revenue
    # account (e.g. an employer) -- neither is tracked in Sure, so the single
    # asset-account entry is correct. A *transfer* is the exception: both sides
    # are real asset accounts, but v1 records only the source-side outflow (the
    # destination doesn't receive the matching inflow -- a documented follow-up).
    # Outflows (withdrawals, transfers) use the source account; deposits use the
    # destination account.
    def account_name(row, amount)
      column = outflow?(row, amount) ? SOURCE_ACCOUNT_COLUMN : DESTINATION_ACCOUNT_COLUMN

      csv_value(row, column).to_s.presence ||
        csv_value(row, account_col_label.presence || "account", "account_name").to_s
    end

    def outflow?(row, amount)
      case transaction_type(row)
      when DEPOSIT_TYPE then false
      when WITHDRAWAL_TYPE, TRANSFER_TYPE then true
      else !amount.nil? && amount.negative?
      end
    end

    def row_date(row)
      value = csv_value(row, date_col_label, "date").to_s
      value[ISO_TIMESTAMP_DATE, 1] || value
    end

    # Opening-balance / reconciliation rows can have a blank description. Entry
    # requires a name, so fall back to the notes column and finally the generic
    # default, mirroring the blank-name handling in Import and YnabImport.
    def row_name(row)
      csv_value(row, name_col_label, "description").to_s.presence ||
        csv_value(row, notes_col_label, "notes").to_s.presence ||
        default_row_name
    end
end
