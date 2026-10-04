require "rails_helper"

RSpec.describe "user rake tasks", type: :task do
  describe "user:delete" do
    let!(:user) { create(:user, email: "robin@example.com") }

    before do
      create(:identity, user: user)
      create(:session, user: user)
      create(:invite, :accepted, email: user.email, user: user)
      budget = create(:budget, user: user)
      envelopes = create_list(:budget_envelope, 2, budget: budget)
      create_list(:budget_deposit, 3, budget: budget)
      # Two months of Assigned amounts, three Spends and two Refunds for each envelope, a Reallocation each way between
      # the two and one to Ready to Assign, which an envelope can't be deleted while it has.
      envelopes.each do |envelope|
        [ Date.new(2026, 9, 1), Date.new(2026, 10, 1) ].each { |month| create(:budget_assignment, envelope: envelope, month: month) }
        create_list(:budget_spend, 3, envelope: envelope)
        create_list(:budget_refund, 2, envelope: envelope)
      end
      create(:budget_envelope_reallocation, from_envelope: envelopes.first, to_envelope: envelopes.last)
      create(:budget_envelope_reallocation, from_envelope: envelopes.last, to_envelope: envelopes.first)
      create(:budget_ready_to_assign_reallocation, envelope: envelopes.first)
      csv_formats = create_list(:budget_csv_format, 2, budget: budget)
      # An Account with two Imports and five bank transactions, and another with an Import of nothing but rows of 0.
      accounts = create_list(:budget_account, 2, budget: budget)
      import = create(:budget_import, account: accounts.first, csv_format: csv_formats.first)
      create_list(:budget_bank_transaction, 5, account: accounts.first, import: import)
      create(:budget_import, account: accounts.first, csv_format: csv_formats.last)
      create(:budget_import, account: accounts.last, csv_format: csv_formats.first, zero_rows_skipped: 1)
    end

    # One bank transaction filed as a Spend and another as a Deposit, and one ignored, which have to go before the rest.
    def file_and_ignore_some_bank_transactions
      budget = user.budget
      filed_out, filed_in, ignored = budget.bank_transactions.order(:id).first(3)
      filed_out.update_column(:amount, -10)
      filed_in.update_column(:amount, 10)
      ignored.update_column(:ignored_at, Time.current)
      create(:budget_spend_link, bank_transaction: filed_out, spend: create(:budget_spend, envelope: budget.envelopes.first, amount: 10))
      create(:budget_deposit_link, bank_transaction: filed_in, deposit: create(:budget_deposit, budget: budget, amount: 10))
    end

    it "deletes the user, their identities, sessions, budget, envelopes, Deposits, Assigned amounts, Spends, Refunds, Reallocations (of both kinds), CSV formats, Accounts, Imports, bank transactions and invite once the email is typed to confirm" do
      output = nil
      file_and_ignore_some_bank_transactions

      expect { output = run_task("user:delete", stdin: "Robin@Example.com\n", "EMAIL" => "robin@example.com") }
        .to change(User, :count).by(-1).and change(Identity, :count).by(-1)
        .and change(Session, :count).by(-1).and change(Invite, :count).by(-1)
        .and change(Budget, :count).by(-1).and change(Budget::Envelope, :count).by(-2)
        .and change(Budget::Deposit, :count).by(-4).and change(Budget::Assignment, :count).by(-4)
        .and change(Budget::Spend, :count).by(-7).and change(Budget::Refund, :count).by(-4)
        .and change(Budget::EnvelopeReallocation, :count).by(-2)
        .and change(Budget::ReadyToAssignReallocation, :count).by(-1)
        .and change(Budget::CsvFormat, :count).by(-2)
        .and change(Budget::Account, :count).by(-2)
        .and change(Budget::Import, :count).by(-3)
        .and change(Budget::BankTransaction, :count).by(-5)
        .and change(Budget::SpendLink, :count).by(-1).and change(Budget::DepositLink, :count).by(-1)
      expect(output).to include("1 identity, 1 session, their budget with 2 envelopes, 4 deposits, 4 assignments, 7 spends, 4 refunds, 3 reallocations, 2 CSV formats, 2 accounts, 3 imports and 5 bank transactions and their invite", "Deleted robin@example.com.")
    end

    it "leaves another user's budget alone" do
      file_and_ignore_some_bank_transactions
      others = create(:budget_assignment)
      others_spend = create(:budget_spend)
      others_refund = create(:budget_refund)
      others_reallocation = create(:budget_envelope_reallocation)
      others_to_ready_to_assign = create(:budget_ready_to_assign_reallocation)
      others_csv_format = create(:budget_csv_format)
      others_transaction = create(:budget_bank_transaction)

      run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(Budget::Assignment.all).to contain_exactly(others)
      expect(Budget::Spend.all).to contain_exactly(others_spend)
      expect(Budget::Refund.all).to contain_exactly(others_refund)
      expect(Budget::EnvelopeReallocation.all).to contain_exactly(others_reallocation)
      expect(Budget::ReadyToAssignReallocation.all).to contain_exactly(others_to_ready_to_assign)
      expect(Budget::CsvFormat.all).to contain_exactly(others_csv_format, others_transaction.import.csv_format)
      expect(Budget::Account.all).to contain_exactly(others_transaction.account)
      expect(Budget::BankTransaction.all).to contain_exactly(others_transaction)
    end

    it "counts a single envelope, a single deposit, a single assignment, a single spend and a single refund in the singular" do
      kept = user.budget.assignments.first
      Budget::Assignment.where(envelope: user.budget.envelopes).where.not(id: kept.id).delete_all
      Budget::Spend.where(envelope: user.budget.envelopes).where.not(id: kept.envelope.spends.first.id).delete_all
      Budget::Refund.where(envelope: user.budget.envelopes).where.not(id: kept.envelope.refunds.first.id).delete_all
      Budget::EnvelopeReallocation.where(from_envelope: user.budget.envelopes).delete_all
      Budget::ReadyToAssignReallocation.where(envelope: user.budget.envelopes).delete_all
      user.budget.envelopes.where.not(id: kept.envelope_id).destroy_all
      user.budget.deposits.where.not(id: user.budget.deposits.first.id).destroy_all
      user.budget.bank_transactions.where.not(id: user.budget.bank_transactions.first.id).delete_all
      Budget::Import.where(account: user.budget.accounts).where.not(id: user.budget.bank_transactions.first.import_id).delete_all
      user.budget.accounts.where.not(id: user.budget.bank_transactions.first.account_id).destroy_all
      user.budget.csv_formats.where.not(id: user.budget.imports.first.csv_format_id).destroy_all

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("their budget with 1 envelope, 1 deposit, 1 assignment, 1 spend, 1 refund, 0 reallocations, 1 CSV format, 1 account, 1 import and 1 bank transaction and their invite")
    end

    it "counts a single reallocation in the singular" do
      user.budget.envelope_reallocations.last.destroy!
      user.budget.ready_to_assign_reallocations.each(&:destroy!)

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("4 refunds, 1 reallocation, 2 CSV formats, 2 accounts, 3 imports and 5 bank transactions and their invite")
    end

    it "counts a budget that has nothing in it" do
      user.budget.assignments.each(&:destroy!)
      user.budget.spends.each(&:destroy!)
      user.budget.refunds.each(&:destroy!)
      user.budget.envelope_reallocations.each(&:destroy!)
      user.budget.ready_to_assign_reallocations.each(&:destroy!)
      user.budget.deposits.destroy_all
      Budget::BankTransaction.where(account: user.budget.accounts).delete_all
      Budget::Import.where(account: user.budget.accounts).delete_all
      user.budget.accounts.destroy_all
      user.budget.csv_formats.destroy_all
      user.budget.envelopes.destroy_all

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("their budget with 0 envelopes, 0 deposits, 0 assignments, 0 spends, 0 refunds, 0 reallocations, 0 CSV formats, 0 accounts, 0 imports and 0 bank transactions and their invite")
    end

    it "says when the user has no budget" do
      user.budget.destroy!

      output = run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(output).to include("1 identity, 1 session, no budget and their invite")
    end

    it "lets the email be invited again afterwards" do
      run_task("user:delete", stdin: "robin@example.com\n", "EMAIL" => "robin@example.com")

      expect(Invite.issue!("robin@example.com")).to be_pending
    end

    it "deletes nothing unless the email is typed" do
      expect { expect_task_failure("user:delete", "Not deleted.\n", stdin: "yes\n", "EMAIL" => "robin@example.com") }
        .not_to change(User, :count)
    end

    it "deletes nothing without input to confirm with" do
      expect { expect_task_failure("user:delete", "Not deleted.\n", stdin: "", "EMAIL" => "robin@example.com") }
        .not_to change(User, :count)
    end

    it "fails for an email without a user" do
      expect_task_failure("user:delete", /No user has the email someone@example.com/, "EMAIL" => "Someone@example.com")
    end

    it "fails without EMAIL" do
      expect_task_failure("user:delete", /Usage: bin\/rails user:delete EMAIL=/, "EMAIL" => nil)
    end
  end
end
