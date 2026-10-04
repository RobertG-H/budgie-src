class CreateBudgetDeposits < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_deposits do |t|
      # Indexed below, together with month.
      t.references :budget, null: false, index: false, foreign_key: { on_delete: :restrict }
      t.string :description, null: false
      t.date :date, null: false
      # The month whose Ready to Assign this Deposit counts toward: the month of its date or the month after.
      t.date :month, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.text :notes, null: false, default: ""

      t.timestamps
    end

    # Serves the balance calculator, and a month's list of Deposits.
    add_index :budget_deposits, [ :budget_id, :month ]

    add_check_constraint :budget_deposits, "btrim(description) <> ''", name: "budget_deposits_description_not_blank"
    add_check_constraint :budget_deposits, "EXTRACT(DAY FROM month) = 1", name: "budget_deposits_month_first_of_month"
    # date_trunc on a date returns a timestamptz, which would make this depend on the session's time zone,
    # so the date is cast to a plain timestamp first.
    add_check_constraint :budget_deposits,
      "month = date_trunc('month', date::timestamp)::date " \
      "OR month = (date_trunc('month', date::timestamp) + interval '1 month')::date",
      name: "budget_deposits_month_of_date_or_next"
    add_check_constraint :budget_deposits, "amount > 0", name: "budget_deposits_amount_positive"
  end
end
