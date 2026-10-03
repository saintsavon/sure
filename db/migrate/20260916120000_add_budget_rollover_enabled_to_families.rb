class AddBudgetRolloverEnabledToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :budget_rollover_enabled, :boolean, default: false, null: false
  end
end
