class CreateBudgetsAndBudgetEnvelopes < ActiveRecord::Migration[8.1]
  def change
    create_table :budgets do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: { on_delete: :restrict }
      t.string :currency, limit: 3, null: false

      t.timestamps
    end
    add_check_constraint :budgets, "currency ~ '^[A-Z]{3}$'", name: "budgets_currency_format"

    create_table :budget_envelopes do |t|
      t.references :budget, null: false, foreign_key: { on_delete: :restrict }
      t.string :name, null: false
      t.decimal :starting_balance, precision: 15, scale: 2, null: false, default: 0

      t.timestamps
    end
    add_check_constraint :budget_envelopes, "btrim(name) <> ''", name: "budget_envelopes_name_not_blank"
    add_index :budget_envelopes, "budget_id, lower(name)", unique: true, name: "index_budget_envelopes_on_budget_id_and_lower_name"
  end
end
