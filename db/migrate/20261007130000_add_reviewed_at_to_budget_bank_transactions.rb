class AddReviewedAtToBudgetBankTransactions < ActiveRecord::Migration[8.1]
  def change
    # When a person looked at what a Filing rule did with a bank transaction (ADR 0017). While a rule filed or ignored it and this is null it's to review.
    # Nullable, which is the importer tables' nulls where absence is real, and left null for every row there is, so what rules filed or ignored before this
    # started out to review, once.
    add_column :budget_bank_transactions, :reviewed_at, :datetime
  end
end
