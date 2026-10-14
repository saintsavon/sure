class CreateDebtPlans < ActiveRecord::Migration[7.2]
  def change
    create_table :debt_plans, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true, index: false
      t.string :state, null: false, default: "active"
      t.string :strategy, null: false, default: "snowball"
      t.decimal :high_interest_line, precision: 6, scale: 4, null: false, default: 0.15
      t.decimal :monthly_surplus, precision: 19, scale: 4, null: false, default: 0
      t.jsonb :surplus_steps, null: false, default: []
      t.date :payday_anchor_on
      t.string :payday_cadence, null: false, default: "biweekly"
      t.decimal :cash_float, precision: 19, scale: 4, null: false, default: 0
      t.uuid :cash_account_ids, array: true, null: false, default: []
      t.references :emergency_fund_goal, type: :uuid, foreign_key: { to_table: :goals }
      t.jsonb :baseline_schedule, null: false, default: []
      t.date :baseline_taken_on
      t.boolean :email_notifications_enabled, null: false, default: false
      t.boolean :discord_notifications_enabled, null: false, default: false
      t.date :email_digest_sent_on
      t.date :discord_digest_sent_on
      t.text :discord_webhook_url
      t.timestamps
    end
    add_index :debt_plans, :family_id, unique: true, where: "state = 'active'"
    add_check_constraint :debt_plans, "strategy IN ('snowball', 'avalanche')", name: "chk_debt_plans_strategy"
    add_check_constraint :debt_plans, "state IN ('active', 'archived')", name: "chk_debt_plans_state"

    create_table :debt_plan_entries, id: :uuid do |t|
      t.references :debt_plan, type: :uuid, null: false, foreign_key: true
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.string :role, null: false, default: "snowball"
      t.integer :priority
      t.decimal :minimum_payment_override, precision: 19, scale: 4
      t.decimal :scheduled_amount, precision: 19, scale: 4
      t.integer :payment_due_day
      t.boolean :frozen_card, null: false, default: false
      t.decimal :starting_balance, precision: 19, scale: 4, null: false, default: 0
      t.text :notes
      t.timestamps
    end
    add_index :debt_plan_entries, [ :debt_plan_id, :account_id ], unique: true
    add_check_constraint :debt_plan_entries, "role IN ('snowball', 'minimum_only', 'scheduled', 'excluded')", name: "chk_debt_plan_entries_role"
    add_check_constraint :debt_plan_entries, "payment_due_day BETWEEN 1 AND 31", name: "chk_debt_plan_entries_due_day"

    create_table :debt_plan_lump_sums, id: :uuid do |t|
      t.references :debt_plan, type: :uuid, null: false, foreign_key: true
      t.date :expected_on, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :label, null: false
      t.date :received_on
      t.boolean :scheduled_payments, null: false, default: true
      t.timestamps
    end

    create_table :debt_plan_events, id: :uuid do |t|
      t.references :debt_plan, type: :uuid, null: false, foreign_key: true
      t.references :account, type: :uuid, foreign_key: true
      t.string :kind, null: false
      t.string :key, null: false
      t.date :occurred_on, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :notified_at
      t.datetime :email_notified_at
      t.datetime :discord_notified_at
      t.datetime :celebrated_at
      t.timestamps
    end
    add_index :debt_plan_events, [ :debt_plan_id, :key ], unique: true

    create_table :debt_plan_snapshots, id: :uuid do |t|
      t.references :debt_plan, type: :uuid, null: false, foreign_key: true
      t.date :taken_on, null: false
      t.decimal :total_debt, precision: 19, scale: 4, null: false
      t.date :projected_debt_free_on
      t.decimal :projected_total_interest, precision: 19, scale: 4, null: false, default: 0
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :debt_plan_snapshots, [ :debt_plan_id, :taken_on ], unique: true
  end
end
