class CreateBudgetReadyToAssignReallocations < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_ready_to_assign_reallocations do |t|
      # A Reallocation to Ready to Assign belongs to its budget through its envelope, so there's no budget_id. The index
      # below starts with the envelope, which is all a lookup by envelope needs.
      t.references :envelope, null: false, index: false, foreign_key: { to_table: :budget_envelopes, on_delete: :restrict }
      t.string :description, null: false
      t.date :date, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.text :notes, null: false, default: ""

      t.timestamps
    end

    # Serves the balance calculator, and an envelope's list of Reallocations for a month. Named by hand, because the
    # default name is longer than PostgreSQL allows.
    add_index :budget_ready_to_assign_reallocations, [ :envelope_id, :date ], name: "index_ready_to_assign_reallocations_on_envelope_id_and_date"

    add_check_constraint :budget_ready_to_assign_reallocations, "btrim(description) <> ''", name: "budget_ready_to_assign_reallocations_description_not_blank"
    add_check_constraint :budget_ready_to_assign_reallocations, "amount > 0", name: "budget_ready_to_assign_reallocations_amount_positive"
  end
end
