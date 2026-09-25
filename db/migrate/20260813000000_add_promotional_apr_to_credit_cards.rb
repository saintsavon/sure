class AddPromotionalAprToCreditCards < ActiveRecord::Migration[7.2]
  def change
    change_table :credit_cards, bulk: true do |t|
      t.decimal :promo_apr, precision: 10, scale: 2
      t.decimal :promo_balance, precision: 10, scale: 2
      t.date :promo_starts_on
      t.date :promo_ends_on
      t.boolean :promo_deferred_interest, default: false, null: false
    end
  end
end
