class CreateBudgetSpends < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_spends do |t|
      # A Spend belongs to its budget through its envelope, so there's no budget_id. The index below starts with the
      # envelope, which is all a lookup by envelope needs.
      t.references :envelope, null: false, index: false, foreign_key: { to_table: :budget_envelopes, on_delete: :restrict }
      t.string :description, null: false
      t.date :date, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.text :notes, null: false, default: ""

      t.timestamps
    end

    # Serves the balance calculator, and an envelope's list of Spends for a month.
    add_index :budget_spends, [ :envelope_id, :date ]

    add_check_constraint :budget_spends, "btrim(description) <> ''", name: "budget_spends_description_not_blank"
    add_check_constraint :budget_spends, "amount > 0", name: "budget_spends_amount_positive"
  end
end
