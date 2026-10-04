class AddArchivedAtToBudgetEnvelopes < ActiveRecord::Migration[8.1]
  def change
    # Null while the envelope is in use, and the time it was archived otherwise. It has no default.
    add_column :budget_envelopes, :archived_at, :datetime
  end
end
