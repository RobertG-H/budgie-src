class CreateBudgetAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_assignments do |t|
      # An Assignment belongs to its budget through its envelope, so there's no budget_id. The unique index below
      # starts with the envelope, which is all a lookup by envelope needs.
      t.references :envelope, null: false, index: false, foreign_key: { to_table: :budget_envelopes, on_delete: :restrict }
      # The month this money is assigned in, as the 1st.
      t.date :month, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false

      t.timestamps
    end

    # One figure per envelope per month, edited in place. It also serves the balance calculator.
    add_index :budget_assignments, [ :envelope_id, :month ], unique: true

    add_check_constraint :budget_assignments, "EXTRACT(DAY FROM month) = 1", name: "budget_assignments_month_first_of_month"
    # To assign nothing, delete the row.
    add_check_constraint :budget_assignments, "amount > 0", name: "budget_assignments_amount_positive"
  end
end
