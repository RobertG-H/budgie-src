require "rails_helper"
require Rails.root.join("db/migrate/20261004200000_add_default_csv_format_to_budget_accounts")

# The migration that gave an Account a default CSV format recognises the Accounts that already had Imports from day one, from their latest
# Import's format, which is a statement in SQL. It's run here the way the migration runs it.
RSpec.describe AddDefaultCsvFormatToBudgetAccounts do
  let(:budget) { create(:budget) }
  let(:first_format) { create(:budget_csv_format, budget: budget, name: "First") }
  let(:second_format) { create(:budget_csv_format, budget: budget, name: "Second") }
  let(:third_format) { create(:budget_csv_format, budget: budget, name: "Third") }

  def backfill
    Budget::Account.update_all(default_csv_format_id: nil)
    ActiveRecord::Base.connection.execute(AddDefaultCsvFormatToBudgetAccounts::BACKFILL)
  end

  it "gives an Account the CSV format of its latest Import, by when it ran" do
    account = create(:budget_account, budget: budget)
    create(:budget_import, account: account, csv_format: first_format, created_at: 3.days.ago)
    create(:budget_import, account: account, csv_format: second_format, created_at: 1.hour.ago)
    create(:budget_import, account: account, csv_format: third_format, created_at: 2.days.ago)

    backfill

    expect(account.reload.default_csv_format).to eq(second_format)
  end

  it "goes by the order they were made in when two ran at the same moment" do
    account = create(:budget_account, budget: budget)
    moment = Time.zone.local(2026, 9, 15, 10)
    create(:budget_import, account: account, csv_format: first_format, created_at: moment)
    create(:budget_import, account: account, csv_format: second_format, created_at: moment)

    backfill

    expect(account.reload.default_csv_format).to eq(second_format)
  end

  it "leaves an Account without an Import without one" do
    account = create(:budget_account, budget: budget)

    backfill

    expect(account.reload.default_csv_format).to be_nil
  end

  it "keeps each Account's own, and another budget's Accounts theirs" do
    mine = create(:budget_account, budget: budget)
    other_mine = create(:budget_account, budget: budget)
    create(:budget_import, account: mine, csv_format: first_format)
    create(:budget_import, account: other_mine, csv_format: second_format)
    others = create(:budget_import)

    backfill

    expect(mine.reload.default_csv_format).to eq(first_format)
    expect(other_mine.reload.default_csv_format).to eq(second_format)
    expect(others.account.reload.default_csv_format).to eq(others.csv_format)
  end

  it "does the whole table in one statement, however many Accounts there are" do
    5.times { create(:budget_import, csv_format: first_format, account: create(:budget_account, budget: budget)) }
    Budget::Account.update_all(default_csv_format_id: nil)

    queries = count_queries { ActiveRecord::Base.connection.execute(AddDefaultCsvFormatToBudgetAccounts::BACKFILL) }

    expect(queries).to eq(1)
    expect(Budget::Account.where(default_csv_format_id: nil)).to be_empty
  end
end
