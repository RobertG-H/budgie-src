class MoveReadFromToBudgetAccounts < ActiveRecord::Migration[8.1]
  # Every synced Account takes its connection's date, a disconnected one's too. An Account that isn't synced has none. A constant, so that a spec can run the very
  # statement the migration does.
  BACKFILL = <<~SQL.squish
    UPDATE budget_accounts SET read_from = budget_bank_connections.read_from
    FROM budget_bank_connections
    WHERE budget_bank_connections.id = budget_accounts.bank_connection_id
  SQL

  # The way back, for a rollback: a connection takes the date of its first Account, which for Splitwise is its only one, and one with no Account, which
  # nothing should leave behind, the 1st of this month, as a new connection did.
  RESTORE = <<~SQL.squish
    UPDATE budget_bank_connections SET read_from = first.read_from
    FROM (
      SELECT DISTINCT ON (bank_connection_id) bank_connection_id, read_from
      FROM budget_accounts
      WHERE bank_connection_id IS NOT NULL
      ORDER BY bank_connection_id, id
    ) AS first
    WHERE first.bank_connection_id = budget_bank_connections.id
  SQL

  # The date to read from belongs to each Account, so that a connection with several (a bank's, through Plaid) can give each its own (ADR 0018). It's set only
  # for a synced Account, and the 1990 floor moves with it; "no later than tomorrow" depends on the day, so it stays in the model.
  def up
    add_column :budget_accounts, :read_from, :date
    execute BACKFILL
    add_check_constraint :budget_accounts, "(bank_connection_id IS NULL) = (read_from IS NULL)", name: "budget_accounts_read_from_when_synced"
    add_check_constraint :budget_accounts, "read_from >= DATE '1990-01-01'", name: "budget_accounts_read_from_not_before_1990"

    remove_check_constraint :budget_bank_connections, name: "budget_bank_connections_read_from_not_before_1990"
    remove_column :budget_bank_connections, :read_from
  end

  def down
    add_column :budget_bank_connections, :read_from, :date
    execute RESTORE
    execute "UPDATE budget_bank_connections SET read_from = date_trunc('month', CURRENT_DATE)::date WHERE read_from IS NULL"
    change_column_null :budget_bank_connections, :read_from, false
    add_check_constraint :budget_bank_connections, "read_from >= DATE '1990-01-01'", name: "budget_bank_connections_read_from_not_before_1990"

    remove_check_constraint :budget_accounts, name: "budget_accounts_read_from_not_before_1990"
    remove_check_constraint :budget_accounts, name: "budget_accounts_read_from_when_synced"
    remove_column :budget_accounts, :read_from
  end
end
