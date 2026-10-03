class AddPositionToRules < ActiveRecord::Migration[7.2]
  def change
    add_column :rules, :position, :integer, default: 0, null: false

    # Give existing rules a stable 0..n-1 order per family (oldest first), so
    # users see the same sequence they had before explicit ordering existed.
    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE rules
          SET position = ranked.new_position
          FROM (
            SELECT id,
                   ROW_NUMBER() OVER (PARTITION BY family_id ORDER BY created_at, id) - 1 AS new_position
            FROM rules
          ) AS ranked
          WHERE rules.id = ranked.id
        SQL
      end
    end

    add_index :rules, [ :family_id, :position ]

    # The composite [family_id, position] index serves family_id-prefix lookups,
    # so the pre-existing standalone family_id index is redundant. Drop it so
    # writes don't maintain two overlapping indexes.
    remove_index :rules, column: :family_id, name: "index_rules_on_family_id"
  end
end
