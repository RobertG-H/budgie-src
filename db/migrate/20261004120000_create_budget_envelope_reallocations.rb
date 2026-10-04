class CreateBudgetEnvelopeReallocations < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_envelope_reallocations do |t|
      # A Reallocation belongs to its budget through its From envelope, so there's no budget_id. The two indexes below
      # each start with an envelope, which is all a lookup by either side needs.
      t.references :from_envelope, null: false, index: false, foreign_key: { to_table: :budget_envelopes, on_delete: :restrict }
      t.references :to_envelope, null: false, index: false, foreign_key: { to_table: :budget_envelopes, on_delete: :restrict }
      t.string :description, null: false
      t.date :date, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.text :notes, null: false, default: ""

      t.timestamps
    end

    # Serve the balance calculator, and an envelope's list of Reallocations for a month, out of it and into it. Named
    # by hand, because the default names are longer than PostgreSQL allows.
    add_index :budget_envelope_reallocations, [ :from_envelope_id, :date ], name: "index_envelope_reallocations_on_from_envelope_id_and_date"
    add_index :budget_envelope_reallocations, [ :to_envelope_id, :date ], name: "index_envelope_reallocations_on_to_envelope_id_and_date"

    add_check_constraint :budget_envelope_reallocations, "btrim(description) <> ''", name: "budget_envelope_reallocations_description_not_blank"
    add_check_constraint :budget_envelope_reallocations, "amount > 0", name: "budget_envelope_reallocations_amount_positive"
    add_check_constraint :budget_envelope_reallocations, "from_envelope_id <> to_envelope_id", name: "budget_envelope_reallocations_envelopes_differ"
  end
end
