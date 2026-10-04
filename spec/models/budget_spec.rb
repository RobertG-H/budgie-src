require "rails_helper"

RSpec.describe Budget, type: :model do
  subject { build(:budget) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to have_many(:envelopes).class_name("Budget::Envelope").dependent(:destroy) }
  it { is_expected.to have_many(:deposits).class_name("Budget::Deposit").dependent(:destroy) }
  it { is_expected.to have_many(:csv_formats).class_name("Budget::CsvFormat").dependent(:destroy) }
  it { is_expected.to have_many(:accounts).class_name("Budget::Account").dependent(:destroy) }
  it { is_expected.to have_many(:filing_rules).class_name("Budget::FilingRule").dependent(:destroy) }
  it { is_expected.to have_many(:imports).through(:accounts) }
  it { is_expected.to have_many(:bank_transactions).through(:accounts) }
  it { is_expected.to have_many(:assignments).through(:envelopes) }
  it { is_expected.to have_many(:spends).through(:envelopes) }
  it { is_expected.to have_many(:refunds).through(:envelopes) }
  it { is_expected.to have_many(:envelope_reallocations).through(:envelopes).source(:outgoing_reallocations) }
  it { is_expected.to have_many(:ready_to_assign_reallocations).through(:envelopes) }
  it { is_expected.to validate_presence_of(:currency) }
  it { is_expected.to validate_inclusion_of(:currency).in_array(Budget::CURRENCIES.keys).with_message("isn't supported") }

  it "supports only three-letter uppercase codes" do
    expect(Budget::CURRENCIES.keys).to all(match(/\A[A-Z]{3}\z/))
  end

  it "rejects a currency that isn't supported" do
    budget = build(:budget, currency: "JPY")

    expect(budget).not_to be_valid
    expect(budget.errors.full_messages).to eq([ "Currency isn't supported" ])
  end

  it "names the currency options with their codes" do
    expect(Budget.currency_options).to include([ "Canadian dollar (CAD)", "CAD" ])
  end

  it "knows its currency's unit" do
    expect(build(:budget, currency: "GBP").currency_unit).to eq("£")
  end

  it "names nested models without the Budget prefix in routes and params" do
    expect(Budget::Envelope.model_name).to have_attributes(route_key: "envelopes", param_key: "envelope")
    expect(Budget::Deposit.model_name).to have_attributes(route_key: "deposits", param_key: "deposit")
    expect(Budget::Assignment.model_name).to have_attributes(route_key: "assignments", param_key: "assignment")
    expect(Budget::Spend.model_name).to have_attributes(route_key: "spends", param_key: "spend")
    expect(Budget::Refund.model_name).to have_attributes(route_key: "refunds", param_key: "refund")
  end

  describe "#assignments" do
    it "are the Assigned amounts of its envelopes, and no other budget's" do
      budget = create(:budget)
      mine = create(:budget_assignment, envelope: create(:budget_envelope, budget: budget))
      create(:budget_assignment)

      expect(budget.assignments).to contain_exactly(mine)
    end
  end

  describe "#spends" do
    it "are the Spends of its envelopes, and no other budget's" do
      budget = create(:budget)
      mine = create(:budget_spend, envelope: create(:budget_envelope, budget: budget))
      create(:budget_spend)

      expect(budget.spends).to contain_exactly(mine)
    end
  end

  describe "#refunds" do
    it "are the Refunds of its envelopes, and no other budget's" do
      budget = create(:budget)
      mine = create(:budget_refund, envelope: create(:budget_envelope, budget: budget))
      create(:budget_refund)

      expect(budget.refunds).to contain_exactly(mine)
    end
  end

  describe "#envelope_reallocations" do
    it "are the Reallocations between its envelopes, each once, and no other budget's" do
      budget = create(:budget)
      mine = create(:budget_envelope_reallocation, from_envelope: create(:budget_envelope, budget: budget))
      back = create(:budget_envelope_reallocation, from_envelope: mine.to_envelope, to_envelope: mine.from_envelope)
      create(:budget_envelope_reallocation)

      expect(budget.envelope_reallocations).to contain_exactly(mine, back)
    end
  end

  describe "#ready_to_assign_reallocations" do
    it "are the Reallocations out of its envelopes to Ready to Assign, and no other budget's" do
      budget = create(:budget)
      mine = create(:budget_ready_to_assign_reallocation, envelope: create(:budget_envelope, budget: budget))
      create(:budget_ready_to_assign_reallocation)

      expect(budget.ready_to_assign_reallocations).to contain_exactly(mine)
    end
  end

  describe "#assignments_copied_through" do
    it "is a new budget's first month, which gets no copy, by the app's time zone" do
      # Still September 30 in Eastern Time.
      travel_to Time.utc(2026, 10, 1, 0, 30) do
        expect(create(:budget).assignments_copied_through).to eq(Date.new(2026, 9, 1))
      end
    end
  end

  describe "#start_new_months" do
    let(:september) { Date.new(2026, 9, 1) }
    let(:october) { Date.new(2026, 10, 1) }

    # A budget that began in September, with a few envelopes.
    let!(:budget) { travel_to(Time.zone.local(2026, 9, 5)) { create(:budget) } }
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
    let!(:rent) { create(:budget_envelope, budget: budget, name: "Rent") }
    let!(:fun) { create(:budget_envelope, budget: budget, name: "Fun") }

    def assign(envelope, amount, month)
      create(:budget_assignment, envelope: envelope, amount: amount, month: month)
    end

    # What each envelope has assigned in `month`, as the month view shows it.
    def assigned_in(month)
      Budget::Month.new(budget, month).envelopes.to_h { |line| [ line.envelope.name, line.assigned ] }
    end

    # Midnight in Eastern Time has just passed on the 1st of `month`.
    def travel_to_start_of(month)
      travel_to month.in_time_zone + 1.minute
    end

    it "gives each envelope the month before's Assigned when a month begins" do
      assign groceries, 400, september
      assign rent, 1500, september

      travel_to_start_of october
      budget.start_new_months

      expect(assigned_in(october)).to eq("Fun" => 0, "Groceries" => 400, "Rent" => 1500)
    end

    it "keeps an amount entered ahead for the new month, and still copies the other envelopes" do
      assign groceries, 400, september
      assign rent, 1500, september
      assign groceries, 450, october

      travel_to_start_of october
      budget.start_new_months

      expect(assigned_in(october)).to eq("Fun" => 0, "Groceries" => 450, "Rent" => 1500)
    end

    it "gives nothing to an envelope that had nothing assigned the month before" do
      assign groceries, 400, september

      travel_to_start_of october
      budget.start_new_months

      expect(assigned_in(october)).to eq("Fun" => 0, "Groceries" => 400, "Rent" => 0)
    end

    it "leaves an amount the user cleared or changed after the month began as they left it" do
      assign groceries, 400, september
      assign rent, 1500, september
      travel_to_start_of october
      budget.start_new_months

      groceries.assign(october, "")
      rent.assign(october, "1400")
      budget.start_new_months

      expect(assigned_in(october)).to eq("Fun" => 0, "Groceries" => 0, "Rent" => 1400)
    end

    it "catches up on the months it missed, in order, each copied from the month before" do
      assign groceries, 400, september
      assign rent, 1500, september
      assign groceries, 450, october

      # Nothing ran when October began.
      travel_to_start_of Date.new(2026, 11, 1)
      budget.start_new_months

      expect(assigned_in(october)).to eq("Fun" => 0, "Groceries" => 450, "Rent" => 1500)
      expect(assigned_in(Date.new(2026, 11, 1))).to eq("Fun" => 0, "Groceries" => 450, "Rent" => 1500)
    end

    it "gives a new budget's first month no copy, even when the month before has amounts" do
      assign groceries, 400, Date.new(2026, 8, 1)

      travel_to Time.zone.local(2026, 9, 20)
      budget.start_new_months

      expect(assigned_in(september)).to eq("Fun" => 0, "Groceries" => 0, "Rent" => 0)
    end

    it "doesn't change the new month when a month that has already begun is changed" do
      assign groceries, 400, september
      travel_to_start_of october
      budget.start_new_months

      groceries.assign(september, "300")
      budget.start_new_months

      expect(assigned_in(september)).to include("Groceries" => 300)
      expect(assigned_in(october)).to include("Groceries" => 400)
    end

    it "gives the same result when it runs twice as when it runs once" do
      assign groceries, 400, september
      assign rent, 1500, september
      travel_to_start_of october
      budget.start_new_months

      expect { budget.start_new_months }.not_to change { assigned_in(october) }
    end

    describe "with an archived envelope" do
      let(:april) { Date.new(2026, 4, 1) }
      let(:march) { Date.new(2026, 3, 1) }

      # What an envelope has assigned, as [ month, amount ] pairs. It reads the Assignments themselves, since the month view
      # doesn't show an archived envelope in a month where it has nothing.
      def assigned(envelope)
        Budget::Assignment.where(envelope: envelope).order(:month).pluck(:month, :amount)
      end

      before do
        budget.update!(assignments_copied_through: march)
        assign fun, 40, march
        assign groceries, 400, march
        fun.update_column(:archived_at, Time.current)
      end

      it "doesn't copy its Assigned into the month that begins, and copies an envelope in use's" do
        travel_to_start_of april
        budget.start_new_months

        expect(assigned(fun)).to eq([ [ march, 40 ] ])
        expect(assigned(groceries)).to eq([ [ march, 400 ], [ april, 400 ] ])
      end

      it "gives an envelope unarchived later no copy for the months it missed" do
        travel_to_start_of april
        budget.start_new_months
        travel_to_start_of Date.new(2026, 5, 1)
        budget.start_new_months

        fun.unarchive
        travel_to_start_of Date.new(2026, 6, 1)
        budget.start_new_months

        expect(assigned(fun)).to eq([ [ march, 40 ] ])
        expect(assigned(groceries).map(&:first)).to eq([ march, april, Date.new(2026, 5, 1), Date.new(2026, 6, 1) ])
      end

      it "doesn't touch the Assigned entered ahead for it" do
        fun.update_column(:archived_at, nil)
        assign fun, 15, april
        fun.update_column(:archived_at, Time.current)
        travel_to_start_of april

        expect { budget.start_new_months }.not_to change { assigned(fun) }
      end

      it "takes as many queries as with no archived envelope" do
        travel_to_start_of april
        with_it = count_queries { budget.start_new_months }

        other = travel_to(Time.zone.local(2026, 3, 5)) { create(:budget) }
        create(:budget_assignment, envelope: create(:budget_envelope, budget: other, name: "Groceries"), month: march, amount: 400)
        create(:budget_assignment, envelope: create(:budget_envelope, budget: other, name: "Fun"), month: march, amount: 40)
        travel_to_start_of april
        without_it = count_queries { other.start_new_months }

        expect(with_it).to eq(without_it)
      end
    end

    it "takes as many queries for 20 envelopes as for 1" do
      budgets = [ 1, 20 ].map do |count|
        travel_to(Time.zone.local(2026, 9, 5)) { create(:budget) }.tap do |budget|
          create_list(:budget_envelope, count, budget: budget).each { |envelope| assign envelope, 100, september }
        end
      end

      travel_to_start_of october
      counts = budgets.map { |budget| count_queries { budget.start_new_months } }

      expect(budgets.map { |budget| budget.assignments.where(month: october).count }).to eq([ 1, 20 ])
      expect(counts.first).to eq(counts.last)
    end
  end

  describe "being destroyed" do
    let(:budget) { create(:budget) }

    # Two envelopes with records, a third that only has Reallocations, a Deposit, and an envelope with nothing recorded
    # against it.
    before do
      groceries, rent, extra = create_list(:budget_envelope, 3, budget: budget)
      create(:budget_envelope, budget: budget)
      @groceries = groceries
      [ groceries, rent ].each do |envelope|
        [ Date.new(2026, 9, 1), Date.new(2026, 10, 1) ].each { |month| create(:budget_assignment, envelope: envelope, month: month) }
        create_list(:budget_spend, 3, envelope: envelope)
        create_list(:budget_refund, 2, envelope: envelope)
      end
      # Each of the three envelopes gives to the next one and receives from it, so every one has Reallocations both ways.
      [ [ groceries, rent ], [ rent, extra ], [ extra, groceries ] ].each do |from, to|
        create_list(:budget_envelope_reallocation, 2, from_envelope: from, to_envelope: to)
      end
      create_list(:budget_ready_to_assign_reallocation, 2, envelope: groceries)
      create(:budget_ready_to_assign_reallocation, envelope: extra)
      create(:budget_deposit, budget: budget)
      create_list(:budget_csv_format, 2, budget: budget)
      # Two Accounts, one with two Imports and bank transactions, and one with an Import of nothing but rows of 0, which an
      # Import and its bank transactions keep their Account and CSV format from being deleted before they are.
      busy, quiet = create_list(:budget_account, 2, budget: budget)
      import = create(:budget_import, account: busy, csv_format: budget.csv_formats.first)
      create_list(:budget_bank_transaction, 3, account: busy, import: import)
      create(:budget_import, account: busy, csv_format: budget.csv_formats.last)
      create(:budget_import, account: quiet, csv_format: budget.csv_formats.first, zero_rows_skipped: 2)
      # Accounts' default CSV formats, which keep a CSV format from being deleted before the Accounts are.
      busy.update!(default_csv_format: budget.csv_formats.last)
      quiet.update!(default_csv_format: budget.csv_formats.first)
      # A bank transaction filed as a Spend and another as a Deposit, whose records keep them from being deleted first.
      filed_out, filed_in = import.bank_transactions.first(2)
      filed_out.update_column(:amount, -10)
      filed_in.update_column(:amount, 10)
      create(:budget_spend_link, bank_transaction: filed_out, spend: create(:budget_spend, envelope: @groceries, amount: 10))
      create(:budget_deposit_link, bank_transaction: filed_in, deposit: create(:budget_deposit, budget: budget, amount: 10))
      # Filing rules for an envelope, for an Account and for neither, and a bank transaction that one of them filed, which keeps
      # that rule from being deleted before it's gone.
      spend_rule = create(:budget_filing_rule, budget: budget, envelope: @groceries, text: "loblaws")
      create(:budget_filing_rule, :ignore, budget: budget, account: busy, text: "payment thank you")
      create(:budget_filing_rule, :deposit, budget: budget, text: "payroll")
      filed_out.update_column(:filing_rule_id, spend_rule.id)
    end

    it "deletes its envelopes' records first, since an envelope with records can't be deleted, and then everything else" do
      expect { budget.destroy! }
        .to change(Budget, :count).by(-1)
        .and change(Budget::Envelope, :count).by(-4)
        .and change(Budget::Assignment, :count).by(-4)
        .and change(Budget::Spend, :count).by(-7)
        .and change(Budget::Refund, :count).by(-4)
        .and change(Budget::EnvelopeReallocation, :count).by(-6)
        .and change(Budget::ReadyToAssignReallocation, :count).by(-3)
        .and change(Budget::Deposit, :count).by(-2)
        .and change(Budget::CsvFormat, :count).by(-2)
        .and change(Budget::Account, :count).by(-2)
        .and change(Budget::Import, :count).by(-3)
        .and change(Budget::BankTransaction, :count).by(-3)
        .and change(Budget::SpendLink, :count).by(-1)
        .and change(Budget::DepositLink, :count).by(-1)
        .and change(Budget::FilingRule, :count).by(-3)
    end

    it "deletes its Accounts before its CSV formats, since an Account's default CSV format keeps its format from being deleted" do
      expect(budget.accounts.where.not(default_csv_format_id: nil).count).to eq(2)

      expect { budget.destroy! }.not_to raise_error

      expect(Budget::Account.where(budget_id: budget.id)).to be_empty
      expect(Budget::CsvFormat.where(budget_id: budget.id)).to be_empty
    end

    it "leaves another budget's records alone" do
      others = create(:budget_assignment)
      others_spend = create(:budget_spend)
      others_refund = create(:budget_refund)
      others_reallocation = create(:budget_envelope_reallocation)
      others_to_ready_to_assign = create(:budget_ready_to_assign_reallocation)
      others_csv_format = create(:budget_csv_format)
      others_transaction = create(:budget_bank_transaction, :filed)
      others_rule = create(:budget_filing_rule, text: "loblaws")
      others_transaction.update_column(:filing_rule_id, others_rule.id)

      budget.destroy!

      expect(Budget::Assignment.all).to contain_exactly(others)
      expect(Budget::Spend.all).to contain_exactly(others_spend, others_transaction.spend_links.sole.spend)
      expect(Budget::Refund.all).to contain_exactly(others_refund)
      expect(Budget::EnvelopeReallocation.all).to contain_exactly(others_reallocation)
      expect(Budget::ReadyToAssignReallocation.all).to contain_exactly(others_to_ready_to_assign)
      expect(Budget::CsvFormat.all).to contain_exactly(others_csv_format, others_transaction.import.csv_format)
      expect(Budget::BankTransaction.all).to contain_exactly(others_transaction)
      expect(Budget::FilingRule.all).to contain_exactly(others_rule)
      expect(others_transaction.reload.filing_rule_id).to eq(others_rule.id)
      expect(Budget::SpendLink.count).to eq(1)
      expect(Budget::Envelope.exists?(others.envelope_id)).to be(true)
    end
  end

  describe "database constraints" do
    it "allows only one budget per user" do
      budget = create(:budget)

      expect { Budget.new(user: budget.user, currency: "USD").save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    [ "cad", "CA1" ].each do |currency|
      it "rejects the currency code #{currency}, which isn't three uppercase letters" do
        budget = create(:budget)

        expect { budget.update_column(:currency, currency) }.to raise_error(ActiveRecord::CheckViolation)
      end
    end

    it "rejects an assignments_copied_through that isn't the first of a month" do
      budget = create(:budget)

      expect { budget.update_column(:assignments_copied_through, Date.new(2026, 9, 15)) }
        .to raise_error(ActiveRecord::CheckViolation, /budgets_assignments_copied_through_first_of_month/)
    end

    it "keeps a user with a budget from being deleted without it" do
      budget = create(:budget)

      expect { User.where(id: budget.user_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
