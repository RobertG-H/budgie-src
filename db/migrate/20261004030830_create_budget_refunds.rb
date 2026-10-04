class CreateBudgetRefunds < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_refunds do |t|
      # A Refund belongs to its budget through its envelope, so there's no budget_id. The index below starts with the
      # envelope, which is all a lookup by envelope needs.
      t.references :envelope, null: false, index: false, foreign_key: { to_table: :budget_envelopes, on_delete: :restrict }
      t.string :description, null: false
      t.date :date, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.text :notes, null: false, default: ""

      t.timestamps
    end

    # Serves the balance calculator, and an envelope's list of Refunds for a month.
    add_index :budget_refunds, [ :envelope_id, :date ]

    add_check_constraint :budget_refunds, "btrim(description) <> ''", name: "budget_refunds_description_not_blank"
    add_check_constraint :budget_refunds, "amount > 0", name: "budget_refunds_amount_positive"
  end
end
