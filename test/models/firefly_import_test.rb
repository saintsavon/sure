require "test_helper"

class FireflyImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "default column mappings are applied after create" do
    import = @family.imports.create!(type: "FireflyImport")

    FireflyImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
  end

  test "is a registered import type" do
    assert_includes Import::TYPES, "FireflyImport"
  end

  test "generated rows preserve stable source row numbers" do
    import = firefly_import(file_fixture("imports/firefly.csv").read)
    import.generate_rows_from_csv

    assert_equal (1..5).to_a, import.rows.order(:source_row_number).pluck(:source_row_number)
    assert_equal 5, import.reload.rows_count
  end

  test "withdrawals and transfers become positive (expense) amounts and deposits negative (income) amounts" do
    import = firefly_import(file_fixture("imports/firefly.csv").read)
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    # Row 1: withdrawal -1500 -> an expense, stored positive in Sure's convention
    assert_equal BigDecimal("1500"), rows.first.signed_amount
    # Row 3: deposit 2500 -> income, stored negative in Sure's convention
    assert_equal BigDecimal("-2500"), rows.third.signed_amount
    # Row 4: transfer 250 -> an outflow from the source account, stored positive
    assert_equal BigDecimal("250"), rows.fourth.signed_amount
  end

  test "picks the asset account from the source for outflows and the destination for inflows" do
    import = firefly_import(file_fixture("imports/firefly.csv").read)
    import.generate_rows_from_csv

    accounts = import.rows.order(:source_row_number).pluck(:account)
    # withdrawal -> source, withdrawal -> source, deposit -> destination,
    # transfer -> source, opening balance (positive) -> destination
    assert_equal [ "Checking", "Credit Card", "Checking", "Checking", "Checking" ], accounts
  end

  test "maps the flat category, description, notes and currency" do
    import = firefly_import(file_fixture("imports/firefly.csv").read)
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal "Housing", rows.first.category
    assert_equal "", rows.fourth.category
    assert_equal "Landlord", rows.first.name
    assert_equal "January rent", rows.first.notes
    assert_equal "USD", rows.first.currency
  end

  test "strips the time and offset from Firefly's ISO 8601 timestamps" do
    import = firefly_import(file_fixture("imports/firefly.csv").read)
    import.generate_rows_from_csv

    row = import.rows.order(:source_row_number).first
    assert_equal "2024-01-01", row.date
    assert row.valid?
    assert_equal "2024-01-01", row.date_iso
  end

  test "accepts plain calendar dates" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      Withdrawal,-5.00,USD,2024-02-03,Snack,Checking,Shop
    CSV
    import.generate_rows_from_csv

    row = import.rows.first
    assert_equal "2024-02-03", row.date
    assert row.valid?
  end

  test "uses the magnitude and lets the type decide the sign, case-insensitively" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      withdrawal,50.00,USD,2024-03-01,Positive withdrawal,Checking,Shop
      DEPOSIT,-20.00,USD,2024-03-02,Negative deposit,Employer,Checking
      Transfer,-75.00,USD,2024-03-03,Negative transfer,Checking,Savings
    CSV
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal BigDecimal("50"), rows.first.signed_amount    # outflow -> expense, positive
    assert_equal BigDecimal("-20"), rows.second.signed_amount  # inflow -> income, negative
    assert_equal BigDecimal("75"), rows.third.signed_amount    # transfer leaves the source, positive
    assert_equal %w[Checking Checking Checking], rows.pluck(:account)
  end

  test "falls back to the sign of the amount for opening balances and other types" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      Opening balance,300.00,USD,2024-03-04,Opening,(initial balance),Checking
      Reconciliation,-12.50,USD,2024-03-05,Reconcile,Checking,(reconciliation)
    CSV
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal BigDecimal("-300"), rows.first.signed_amount  # positive -> inflow -> income, negative
    assert_equal "Checking", rows.first.account                # destination
    assert_equal BigDecimal("12.5"), rows.second.signed_amount # negative -> outflow -> expense, positive
    assert_equal "Checking", rows.second.account               # source
  end

  test "passes a signed amount through when the export has no type column" do
    import = firefly_import(<<~CSV)
      date,description,amount,source_name,destination_name
      2024-04-01,Employer,2000.00,Employer,Checking
      2024-04-02,Store,-50.00,Checking,Store
    CSV
    import.generate_rows_from_csv

    rows = import.rows.order(:source_row_number)
    assert_equal BigDecimal("-2000"), rows.first.signed_amount # inflow positive -> income negative
    assert_equal "Checking", rows.first.account               # positive -> destination
    assert_equal BigDecimal("50"), rows.second.signed_amount   # outflow negative -> expense positive
    assert_equal "Checking", rows.second.account              # negative -> source
  end

  test "falls back to a generic account column when there is no source or destination" do
    import = firefly_import(<<~CSV)
      date,description,amount,account
      2024-04-03,Store,-10.00,Savings
    CSV
    import.generate_rows_from_csv

    assert_equal "Savings", import.rows.first.account
  end

  test "leaves the account blank when the export has no account columns" do
    import = firefly_import(<<~CSV)
      type,amount,date,description
      Withdrawal,-5.00,2024-04-04,Snack
    CSV
    import.generate_rows_from_csv

    assert_equal "", import.rows.first.account
  end

  test "strips thousands separators from amounts" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      Withdrawal,"-1,234.56",USD,2024-05-01,Big Bill,Checking,Utilities
    CSV
    import.generate_rows_from_csv

    assert_equal BigDecimal("1234.56"), import.rows.first.signed_amount
  end

  test "uses the currency_code column and falls back to the default currency" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      Withdrawal,-5.00,EUR,2024-05-02,Euro snack,Checking,Shop
    CSV
    import.generate_rows_from_csv

    assert_equal "EUR", import.rows.first.currency

    no_currency = firefly_import(<<~CSV)
      type,amount,date,description,source_name,destination_name
      Withdrawal,-5.00,2024-05-02,Snack,Checking,Shop
    CSV
    no_currency.generate_rows_from_csv

    assert_equal @family.currency, no_currency.rows.first.currency
  end

  test "blank description falls back to notes, then to the default row name" do
    import = firefly_import(file_fixture("imports/firefly.csv").read)
    import.generate_rows_from_csv

    # Last row (opening balance) has a blank description but meaningful notes
    assert_equal "Reconciliation balance adjustment",
      import.rows.order(:source_row_number).last.name

    blank_both = firefly_import(<<~CSV)
      type,amount,date,description,notes,source_name,destination_name
      Deposit,0.43,2024-01-04,,,Employer,Checking
    CSV
    blank_both.generate_rows_from_csv

    assert_equal "Imported item", blank_both.rows.order(:source_row_number).first.name
  end

  test "publishes entries on the mapped accounts with the correct signed amounts" do
    import = firefly_import(file_fixture("imports/firefly.csv").read)
    import.generate_rows_from_csv

    import.mappings.create! key: "Housing", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Food", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Income", create_when_empty: true, type: "Import::CategoryMapping"
    import.mappings.create! key: "Checking", mappable: accounts(:depository), type: "Import::AccountMapping"
    import.mappings.create! key: "Credit Card", mappable: accounts(:credit_card), type: "Import::AccountMapping"
    import.reload

    assert_difference -> { Entry.count } => 5, -> { Transaction.count } => 5 do
      import.publish
    end

    assert_equal "complete", import.status

    entries = import.entries.reload
    landlord = entries.find { |e| e.name == "Landlord" }
    coffee = entries.find { |e| e.name == "Coffee Shop" }
    employer = entries.find { |e| e.name == "Employer" }
    transfer = entries.find { |e| e.name == "Move to savings" }

    assert_equal BigDecimal("1500"), landlord.amount      # expense, positive
    assert_equal accounts(:depository), landlord.account
    assert_equal BigDecimal("4.25"), coffee.amount
    assert_equal accounts(:credit_card), coffee.account
    assert_equal BigDecimal("-2500"), employer.amount     # income, negative
    assert_equal accounts(:depository), employer.account
    assert_equal BigDecimal("250"), transfer.amount       # transfer leaves the source account
    assert_equal "Housing", landlord.entryable.category.name
  end

  test "publishes an entry in the row's currency when it differs from the account" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      Withdrawal,-5.00,EUR,2024-06-01,Euro snack,Checking,Shop
    CSV
    import.generate_rows_from_csv
    import.mappings.create! key: "Checking", mappable: accounts(:depository), type: "Import::AccountMapping"
    import.reload
    import.publish

    assert_equal "EUR", import.entries.reload.first.currency
  end

  test "blocks the import when the export has no amount column" do
    import = firefly_import(<<~CSV)
      type,currency_code,date,description,source_name,destination_name
      Withdrawal,USD,2024-01-01,Store,Checking,Shop
    CSV
    import.generate_rows_from_csv

    row = import.rows.first
    # No amount source -> blank amount -> fails the required-column validation
    assert_predicate row.amount.to_s, :blank?
    assert_not row.valid?
    assert_includes row.errors[:amount], "is required"
    assert_not import.cleaned?
  end

  test "blocks the import when the amount is not a number" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      Withdrawal,n/a,USD,2024-01-01,Store,Checking,Shop
    CSV
    import.generate_rows_from_csv

    row = import.rows.first
    assert_predicate row.amount.to_s, :blank?
    assert_not row.valid?
    assert_includes row.errors[:amount], "is required"
    assert_not import.cleaned?
  end

  test "still allows a genuine zero-dollar row when an amount column exists" do
    import = firefly_import(<<~CSV)
      type,amount,currency_code,date,description,source_name,destination_name
      Withdrawal,0.00,USD,2024-01-01,Placeholder,Checking,Shop
    CSV
    import.generate_rows_from_csv

    row = import.rows.first
    assert_equal BigDecimal("0"), row.amount.to_d
    assert_not row.amount.start_with?("-")
    assert_equal BigDecimal("0"), row.signed_amount
    assert row.valid?
  end

  test "csv template is a valid Firefly export that generates clean rows" do
    import = @family.imports.create!(type: "FireflyImport")
    template = import.csv_template

    assert_equal %w[type amount currency_code date description category source_name destination_name notes], template.headers

    templated = firefly_import(template.to_csv)
    templated.generate_rows_from_csv

    rows = templated.rows.order(:source_row_number)
    assert_equal 2, rows.count
    assert rows.all?(&:valid?)
    assert_equal BigDecimal("8.55"), rows.first.signed_amount    # withdrawal -> expense
    assert_equal BigDecimal("-2500"), rows.second.signed_amount  # deposit -> income
    assert_equal %w[Checking Checking], rows.pluck(:account)
  end

  private
    def firefly_import(csv)
      @family.imports.create!(type: "FireflyImport", raw_file_str: csv, col_sep: ",")
    end
end
