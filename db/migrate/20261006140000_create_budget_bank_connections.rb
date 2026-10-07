class CreateBudgetBankConnections < ActiveRecord::Migration[8.1]
  def change
    # How Accounts are synced from outside, instead of imported from a CSV file: a sign-in to a provider (Splitwise first, a bank-sync provider
    # later) that Budgie holds a token for. It belongs to its budget and never to a user, as Accounts and CSV formats do. Importer tables may have
    # nulls where absence is real: a forgotten token, and a sync marker and time that stay empty until something syncs.
    create_table :budget_bank_connections do |t|
      t.references :budget, null: false, index: false, foreign_key: { on_delete: :restrict }
      # Which provider it is, which a check constraint lists. A provider that's added later adds itself there.
      t.string :provider, null: false
      # The provider's id for the login that was signed in (the Splitwise user's id), as a string since another provider's may not be a number, and
      # its name for display. A reconnect refreshes the name and never the id: a different login is a different connection.
      t.string :login_id, null: false
      t.string :login_name, null: false
      # Encrypted by Active Record, so this is ciphertext. Null once it's forgotten (Disconnect).
      t.text :access_token
      # The token is there but the provider has stopped accepting it, which only a sync finds out. Reconnecting clears it.
      t.boolean :needs_reconnect, null: false, default: false
      # Expenses dated before this are never read.
      t.date :read_from, null: false
      # Where the last sync got to, and when it ran. Both empty until the sync ticket syncs.
      t.string :sync_cursor
      t.datetime :synced_at

      t.timestamps
    end

    # One connection for a budget, provider and login. It also serves finding a budget's connections.
    add_index :budget_bank_connections, [ :budget_id, :provider, :login_id ], unique: true, name: "index_budget_bank_connections_on_login"
    add_check_constraint :budget_bank_connections, "provider IN ('splitwise')", name: "budget_bank_connections_provider_known"
    add_check_constraint :budget_bank_connections, "btrim(login_id) <> '' AND btrim(login_name) <> ''", name: "budget_bank_connections_login_not_blank"
    # With no token there's nothing to have stopped working.
    add_check_constraint :budget_bank_connections, "NOT needs_reconnect OR access_token IS NOT NULL", name: "budget_bank_connections_needs_reconnect_has_token"
  end
end
