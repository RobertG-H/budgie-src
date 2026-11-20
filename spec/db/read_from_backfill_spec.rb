require "rails_helper"
require Rails.root.join("db/migrate/20261119120000_move_read_from_to_budget_accounts")

# The migration that moved the date to read from off the connection and onto its Account copies each connection's date onto the Accounts synced from it,
# which is a statement in SQL. The connection's column is gone by now, so it's run here against a stand-in table of the same shape, the way the migration runs it.
RSpec.describe MoveReadFromToBudgetAccounts do
  let(:budget) { create(:budget) }

  # Each example's transaction is rolled back, and the column with it. The model reads its columns first, so it never learns of this one and no later spec
  # writes it, and the statements prepared while it was there are forgotten after.
  before do
    Budget::BankConnection.load_schema
    ActiveRecord::Base.connection.execute("ALTER TABLE budget_bank_connections ADD COLUMN read_from date")
  end

  after { ActiveRecord::Base.connection.clear_cache! }

  def connection_reading_from(date, **attributes)
    create(:budget_bank_connection, budget: budget, **attributes).tap do |connection|
      ActiveRecord::Base.connection.execute(Budget::BankConnection.sanitize_sql_array([ "UPDATE budget_bank_connections SET read_from = ? WHERE id = ?", date, connection.id ]))
    end
  end

  # The Accounts as they were before the migration: with no date, which the constraint the migration adds afterwards would refuse.
  def forget_dates
    ActiveRecord::Base.connection.execute("ALTER TABLE budget_accounts DROP CONSTRAINT budget_accounts_read_from_when_synced")
    Budget::Account.update_all(read_from: nil)
  end

  def backfill
    forget_dates
    ActiveRecord::Base.connection.execute(MoveReadFromToBudgetAccounts::BACKFILL)
  end

  it "gives each synced Account its connection's date, and each connection its own" do
    first = create(:budget_account, :synced, budget: budget, bank_connection: connection_reading_from(Date.new(2026, 9, 15)))
    second = create(:budget_account, :synced, budget: budget, bank_connection: connection_reading_from(Date.new(2025, 1, 1)))

    backfill

    expect(first.reload.read_from).to eq(Date.new(2026, 9, 15))
    expect(second.reload.read_from).to eq(Date.new(2025, 1, 1))
  end

  it "gives a disconnected connection's Account its date too, which it keeps" do
    connection = connection_reading_from(Date.new(2026, 8, 1))
    account = create(:budget_account, :synced, budget: budget, bank_connection: connection)
    connection.disconnect!

    backfill

    expect(account.reload.read_from).to eq(Date.new(2026, 8, 1))
  end

  it "leaves an Account that isn't synced without one" do
    account = create(:budget_account, budget: budget)

    backfill

    expect(account.reload.read_from).to be_nil
  end

  it "does the whole table in one statement, however many Accounts there are" do
    5.times { create(:budget_account, :synced, budget: budget, bank_connection: connection_reading_from(Date.new(2026, 10, 1))) }
    forget_dates

    queries = count_queries { ActiveRecord::Base.connection.execute(MoveReadFromToBudgetAccounts::BACKFILL) }

    expect(queries).to eq(1)
    expect(Budget::Account.where(read_from: nil)).to be_empty
  end
end
