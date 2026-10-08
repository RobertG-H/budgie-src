require "rails_helper"

# db:prepare seeds a new database in every environment, including the testing and production hosts, so the
# development user must only ever be created in development.
RSpec.describe "db/seeds.rb" do
  def run_seeds
    load Rails.root.join("db/seeds.rb")
  end

  it "creates no development user outside development" do
    expect { run_seeds }.not_to change(User, :count)

    expect(User.find_by(email: Dev::USER_EMAIL)).to be_nil
  end

  it "creates no Deposits outside development" do
    expect { run_seeds }.not_to change(Budget::Deposit, :count)
  end

  it "creates no Assigned amounts outside development" do
    expect { run_seeds }.not_to change(Budget::Assignment, :count)
  end

  it "creates no Spends outside development" do
    expect { run_seeds }.not_to change(Budget::Spend, :count)
  end

  it "creates no Refunds outside development" do
    expect { run_seeds }.not_to change(Budget::Refund, :count)
  end

  it "creates no Reallocations outside development" do
    expect { run_seeds }.not_to change(Budget::EnvelopeReallocation, :count)
    expect { run_seeds }.not_to change(Budget::ReadyToAssignReallocation, :count)
  end

  it "creates no CSV formats outside development" do
    expect { run_seeds }.not_to change(Budget::CsvFormat, :count)
  end

  it "creates no Filing rules outside development" do
    expect { run_seeds }.not_to change(Budget::FilingRule, :count)
  end

  it "creates no Accounts, Imports or bank transactions outside development" do
    expect { run_seeds }.not_to change { [ Budget::Account.count, Budget::Import.count, Budget::BankTransaction.count ] }
  end

  it "creates no bank connections outside development" do
    expect { run_seeds }.not_to change(Budget::BankConnection, :count)
  end

  context "in development" do
    before { allow(Rails.env).to receive(:development?).and_return(true) }

    it "creates the user /dev/sign_in signs in as, with a budget and envelopes, and no way in through Google" do
      run_seeds

      user = User.find_by!(email: Dev::USER_EMAIL)
      expect(user.identities).to be_empty
      expect(user.budget.currency).to eq("USD")
      expect(user.budget.envelopes.pluck(:starting_balance)).to include(be_negative, be_zero, be_positive)
    end

    it "adds a $3,000 Paycheck on the 1st of last month and of this month, and none the month before" do
      # Still October 15 in Eastern time.
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      deposits = User.find_by!(email: Dev::USER_EMAIL).budget.deposits.order(:date)
      expect(deposits.pluck(:description, :date, :month, :amount)).to eq([
        [ "Paycheck", Date.new(2026, 9, 1), Date.new(2026, 9, 1), 3000 ],
        [ "Paycheck", Date.new(2026, 10, 1), Date.new(2026, 10, 1), 3000 ]
      ])
    end

    it "assigns $2,840 last month, with the archived envelope's $40, and $3,100 this month, across the envelopes, and none the month before" do
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      budget = User.find_by!(email: Dev::USER_EMAIL).budget
      expect(budget.assignments.group(:month).sum(:amount)).to eq(Date.new(2026, 9, 1) => 2840, Date.new(2026, 10, 1) => 3100)
      expect(budget.assignments.map { |assignment| assignment.envelope.name }.uniq.size).to be > 1
    end

    it "has Ready to Assign read $160 last month and $110 this month, with $50 reallocated to it, and nothing before last month" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      expect(Budget::Month.new(budget, Date.new(2026, 8, 1)).ready_to_assign).to have_attributes(carried_over: 0, deposited: 0, assigned: 0, amount: 0)
      expect(Budget::Month.new(budget, Date.new(2026, 9, 1)).ready_to_assign)
        .to have_attributes(carried_over: 0, deposited: 3000, assigned: 2840, amount: 160)
      expect(Budget::Month.new(budget, Date.new(2026, 10, 1)).ready_to_assign)
        .to have_attributes(carried_over: 160, deposited: 3000, assigned: 3100, reallocated: 50, amount: 110)
    end

    it "leaves an envelope Overspent, so there's one on the month view to see, with nothing assigned to it" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      bills = Budget::Month.new(budget, Date.new(2026, 10, 1)).envelopes.find { |line| line.envelope.name == "Bills" }

      # Its Starting balance of -$30 and the $50 of Hydro that was filed from it.
      expect(bills).to have_attributes(assigned: 0, available: -80, overspent?: true)
    end

    it "spends from the envelopes last month and this month, and nothing before last month" do
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      budget = User.find_by!(email: Dev::USER_EMAIL).budget
      by_month = budget.spends.group_by { |spend| spend.date.beginning_of_month }
      expect(by_month.keys).to contain_exactly(Date.new(2026, 9, 1), Date.new(2026, 10, 1))
      expect(by_month.values.map { |spends| spends.map { |spend| spend.envelope.name }.uniq.size }).to all(be > 1)
    end

    it "gives Fuel no Spends last month, so its page for that month has none to list, and some this month" do
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      fuel = Budget::Envelope.find_by!(name: "Fuel")
      expect(fuel.spends.dated_in(Date.new(2026, 9, 1))).to be_empty
      expect(fuel.spends.dated_in(Date.new(2026, 10, 1))).not_to be_empty
    end

    it "spends enough from Dining out to leave it Overspent this month, and not last month" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      dining_out = ->(month) { Budget::Month.new(budget, month).envelopes.find { |line| line.envelope.name == "Dining out" } }

      expect(dining_out.call(Date.new(2026, 9, 1))).to have_attributes(spent: BigDecimal("110.75"), available: BigDecimal("234.50"), overspent?: false)
      expect(dining_out.call(Date.new(2026, 10, 1))).to have_attributes(spent: BigDecimal("708.50"), available: BigDecimal("-4.00"), overspent?: true)
    end

    it "refunds Groceries this month, once, and no other envelope or month" do
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      budget = User.find_by!(email: Dev::USER_EMAIL).budget
      # The Splitwise Account's filed bank transactions have Refunds of their own, in an envelope of their own, so it's only Groceries' that's counted.
      refund = budget.refunds.merge(Budget::Envelope.where(name: "Groceries")).sole
      expect(refund).to have_attributes(description: "Loblaws return", date: Date.new(2026, 10, 6), amount: BigDecimal("18.75"))
      expect(refund.envelope.name).to eq("Groceries")
      expect(budget.refunds.where.not(envelope: refund.envelope).map { |other| other.envelope.name }.uniq).to eq([ "Shared" ])
    end

    it "raises Groceries' Available by the Refund this month, and not last month's" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      groceries = ->(month) { Budget::Month.new(budget, month).envelopes.find { |line| line.envelope.name == "Groceries" } }

      expect(groceries.call(Date.new(2026, 9, 1))).to have_attributes(refunded: 0, available: BigDecimal("348.20"))
      expect(groceries.call(Date.new(2026, 10, 1))).to have_attributes(refunded: BigDecimal("18.75"), reallocated: -20, available: BigDecimal("894.40"))
    end

    it "reallocates $20 from Groceries to Dining out this month, once, and no other month" do
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      budget = User.find_by!(email: Dev::USER_EMAIL).budget
      reallocation = budget.envelope_reallocations.sole
      expect(reallocation).to have_attributes(description: "Covering the takeout", date: Date.new(2026, 10, 12), amount: 20)
      expect([ reallocation.from_envelope.name, reallocation.to_envelope.name ]).to eq([ "Groceries", "Dining out" ])
    end

    it "covers part of Dining out's overspending with it, and leaves it Overspent, and Groceries with money left" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      line = ->(name, month) { Budget::Month.new(budget, month).envelopes.find { |envelope_line| envelope_line.envelope.name == name } }

      expect(line.call("Dining out", Date.new(2026, 10, 1))).to have_attributes(reallocated: 20, available: BigDecimal("-4.00"), overspent?: true)
      expect(line.call("Groceries", Date.new(2026, 10, 1))).to have_attributes(reallocated: -20, available: BigDecimal("894.40"))
      expect(line.call("Dining out", Date.new(2026, 9, 1))).to have_attributes(reallocated: 0, available: BigDecimal("234.50"))
    end

    it "reallocates $50 from Fuel to Ready to Assign this month, once, and no other month" do
      travel_to Time.utc(2026, 10, 15, 16)

      run_seeds

      budget = User.find_by!(email: Dev::USER_EMAIL).budget
      reallocation = budget.ready_to_assign_reallocations.sole
      expect(reallocation).to have_attributes(description: "Unspent fuel money", date: Date.new(2026, 10, 14), amount: 50)
      expect(reallocation.envelope.name).to eq("Fuel")
    end

    it "lowers what's Available in Fuel by the $50 reallocated to Ready to Assign, and leaves it with money" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      line = ->(month) { Budget::Month.new(budget, month).envelopes.find { |envelope_line| envelope_line.envelope.name == "Fuel" } }

      expect(line.call(Date.new(2026, 10, 1))).to have_attributes(reallocated: -50, available: BigDecimal("480.45"))
      expect(line.call(Date.new(2026, 9, 1))).to have_attributes(reallocated: 0)
    end

    it "leaves Ready to Assign as it was, which only a Reallocation to it changes" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      budget = User.find_by!(email: Dev::USER_EMAIL).budget

      expect(Budget::Month.new(budget, Date.new(2026, 9, 1)).ready_to_assign.amount).to eq(160)
      expect(Budget::Month.new(budget, Date.new(2026, 10, 1)).ready_to_assign.amount).to eq(110)
    end

    describe "the CSV format" do
      let(:budget) { run_seeds && User.find_by!(email: Dev::USER_EMAIL).budget }

      it "reads the signed sample file, so a developer can import it, with its header skipped" do
        csv_format = budget.csv_formats.sole

        reading = csv_format.read(Rails.root.join("spec/fixtures/files/signed-sample.csv").open)

        expect(csv_format.name).to eq("Sample bank")
        expect(reading.refusal).to be_nil
        expect(reading.rows.map(&:description)).to eq([ "Paycheck", "Loblaws", "Hydro", "Coffee shop", "Hydro rebate" ])
        expect(reading.rows.map(&:amount)).to eq([ 2800, BigDecimal("-82.45"), BigDecimal("-65.50"), BigDecimal("-4.25"), BigDecimal("12.25") ])
        expect(reading.zero_rows).to eq(1)
      end

      it "is left as the developer has changed it" do
        budget.csv_formats.sole.update!(date_order: "day_month_year")

        run_seeds

        expect(budget.csv_formats.sole.date_order).to eq("day_month_year")
      end
    end

    describe "the Account" do
      let(:budget) { run_seeds && User.find_by!(email: Dev::USER_EMAIL).budget }

      it "is Chequing, with one Import of the sample file, read with the seeded CSV format" do
        account = budget.accounts.find_by!(name: "Chequing")

        expect(account.name).to eq("Chequing")
        expect(account.imports.sole).to have_attributes(file_name: "signed-sample.csv", csv_format: budget.csv_formats.sole, duplicates_skipped: 0, zero_rows_skipped: 1)
      end

      it "has the sample's five bank transactions, money in and money out, all of them as the file had them" do
        expect(budget.accounts.find_by!(name: "Chequing").bank_transactions.order(:id).pluck(:date, :description, :amount)).to eq([
          [ Date.new(2026, 9, 1), "Paycheck", 2800 ], [ Date.new(2026, 9, 2), "Loblaws", BigDecimal("-82.45") ],
          [ Date.new(2026, 9, 3), "Hydro", BigDecimal("-65.50") ], [ Date.new(2026, 9, 5), "Coffee shop", BigDecimal("-4.25") ],
          [ Date.new(2026, 9, 9), "Hydro rebate", BigDecimal("12.25") ]
        ])
      end

      it "files Loblaws as a Spend from Groceries, ignores Coffee shop, and leaves the other three unfiled, in the Unfiled list" do
        bank_transactions = budget.accounts.find_by!(name: "Chequing").bank_transactions.index_by(&:description)

        expect(bank_transactions["Loblaws"]).to be_filed
        expect(bank_transactions["Loblaws"].spend_links.sole.spend).to have_attributes(
          description: "Loblaws", date: Date.new(2026, 9, 2), amount: BigDecimal("82.45"), envelope: budget.envelopes.find_by!(name: "Groceries")
        )
        expect(bank_transactions["Coffee shop"]).to be_ignored
        expect(budget.accounts.find_by!(name: "Chequing").bank_transactions.unfiled.pluck(:description)).to contain_exactly("Paycheck", "Hydro rebate")
        expect(bank_transactions.values.select(&:filed?).size).to eq(2)
      end

      it "files Hydro as a split across two envelopes, which add up to it" do
        hydro = budget.bank_transactions.find_by!(description: "Hydro")

        expect(hydro).to be_filed
        expect(hydro).to be_adds_up
        expect(hydro.spend_links.map { |link| [ link.spend.envelope.name, link.spend.amount ] })
          .to contain_exactly([ "Bills", BigDecimal("50") ], [ "Rent", BigDecimal("15.5") ])
        expect(hydro.spend_links.map { |link| link.spend.date }.uniq).to eq([ Date.new(2026, 9, 3) ])
      end

      it "counts the filed Spend in Groceries' September like one typed in, and doesn't add up to a flag" do
        spend = budget.bank_transactions.find_by!(description: "Loblaws").spend_links.sole.spend

        expect(Budget::Month.new(budget, Date.new(2026, 9, 1)).envelope_line(spend.envelope_id).spent).to eq(BigDecimal("182.40") + BigDecimal("240.15") + BigDecimal("96.80") + BigDecimal("82.45"))
        expect(budget.bank_transactions.find_by!(description: "Loblaws")).to be_adds_up
      end

      it "changes nothing when it's run again, and leaves a bank transaction the developer has changed" do
        budget.accounts.find_by!(name: "Chequing").bank_transactions.first.update!(description: "Changed")

        expect { run_seeds }.not_to change { [ Budget::Account.count, Budget::Import.count, Budget::BankTransaction.count ] }
        expect(budget.accounts.find_by!(name: "Chequing").bank_transactions.first.description).to eq("Changed")
      end
    end

    describe "the Splitwise Account" do
      let(:budget) { run_seeds && User.find_by!(email: Dev::USER_EMAIL).budget }

      it "is synced from a connection whose token isn't real, with its Filing rules off" do
        account = budget.accounts.find_by!(name: "Splitwise (sample)")

        expect(account).to be_synced
        expect(account).to have_attributes(files_with_rules: false, external_account_id: "1000000")
        expect(account.bank_connection).to have_attributes(provider: "splitwise", login_name: "Dev B.", access_token: "development-token-not-real", budget: budget)
        expect(account.bank_connection).to be_connected
        expect(account.bank_connection.synced_at).to be_present
      end

      it "has a bank transaction in every state a sync can leave one in, which have no Import" do
        account = budget.accounts.find_by!(name: "Splitwise (sample)")
        transactions = account.bank_transactions.index_by(&:description)

        expect(transactions.values).to all(have_attributes(import: nil, external_id: be_present))
        expect(transactions.values_at("Dinner at Nonna's", "Cottage groceries").map(&:state)).to eq([ :unfiled, :unfiled ])
        expect(transactions.values_at("Brunch with friends", "Gas up north").map(&:state)).to eq([ :filed, :filed ])
        expect(transactions.values_at("Brunch with friends", "Gas up north")).to all(be_adds_up)
        expect(transactions["Movie night"]).to be_filed
        expect(transactions["Movie night"]).not_to be_adds_up
        expect(transactions["Taxi home"]).to be_filed
        expect(transactions["Taxi home"]).not_to be_adds_up
        expect(transactions["Taxi home"]).not_to be_records_suit_the_sign
        expect(transactions["Deleted lunch"].state).to eq(:removed)
        expect(transactions["Concert tickets"]).to be_filed
        expect(transactions["Concert tickets"]).to be_removed
        expect(transactions["Jane paid me back"].state).to eq(:ignored)
      end

      it "starts money in from Splitwise as a Refund, which is what its filed ones were filed as" do
        refunds = budget.refunds.where(description: [ "Brunch with friends", "Movie night", "Taxi home", "Concert tickets" ])

        expect(refunds.count).to eq(4)
      end

      it "leaves Chequing the only Account a file can be imported into" do
        expect(budget.accounts.importable.pluck(:name)).to eq([ "Chequing" ])
      end

      it "changes nothing when it's run again, and leaves what the developer changed" do
        budget.accounts.find_by!(name: "Splitwise (sample)").bank_connection.disconnect!

        expect { run_seeds }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }
        expect(budget.accounts.find_by!(name: "Splitwise (sample)").bank_connection).to be_disconnected
      end
    end

    describe "the Filing rules" do
      let(:budget) { run_seeds && User.find_by!(email: Dev::USER_EMAIL).budget }

      before { travel_to Time.utc(2026, 10, 15, 16) }

      it "has one that files Loblaws as a Spend from Groceries, one that ignores Coffee shop, and one for the archived envelope, which is inactive" do
        expect(budget.filing_rules.alphabetical_by_text.map { |rule| [ rule.text, rule.outcome, rule.envelope&.name ] }).to eq([
          [ "coffee shop", "ignore", nil ], [ "gym membership", "spend", "Old gym" ], [ "loblaws", "spend", "Groceries" ]
        ])
        expect(budget.filing_rules.find_by!(text: "gym membership")).to be_inactive
      end

      it "are what filed Loblaws and ignored Coffee shop, in the Import, so the Account's page and the Import's summary show them" do
        loblaws = budget.bank_transactions.find_by!(description: "Loblaws")
        coffee = budget.bank_transactions.find_by!(description: "Coffee shop")

        expect(loblaws.filed_by_rule).to eq(budget.filing_rules.find_by!(text: "loblaws"))
        expect(coffee.filed_by_rule).to eq(budget.filing_rules.find_by!(text: "coffee shop"))
        expect(budget.imports.sole).to have_attributes(filed_by_rules: 1, ignored_by_rules: 1)
        expect(budget.bank_transactions.find_by!(description: "Hydro").filed_by_rule).to be_nil
      end

      it "leaves a rule the developer has changed, and doesn't make another" do
        budget.filing_rules.find_by!(text: "loblaws").update!(outcome: "ignore")

        expect { run_seeds }.not_to change(Budget::FilingRule, :count)

        expect(budget.filing_rules.find_by!(text: "loblaws").outcome).to eq("ignore")
      end
    end

    describe "the archived envelope" do
      before { travel_to Time.utc(2026, 10, 15, 16) }

      let(:budget) { run_seeds && User.find_by!(email: Dev::USER_EMAIL).budget }

      it "is Old gym, with $40 assigned last month and all of it spent, and nothing this month" do
        old_gym = budget.envelopes.archived.sole

        expect(old_gym.name).to eq("Old gym")
        expect(old_gym.assignments.pluck(:month, :amount)).to eq([ [ Date.new(2026, 9, 1), 40 ] ])
        expect(old_gym.spends.pluck(:date, :amount)).to eq([ [ Date.new(2026, 9, 15), 40 ] ])
      end

      it "shows on last month's view, with nothing Available, and not on this month's" do
        last_month = Budget::Month.new(budget, Date.new(2026, 9, 1))
        this_month = Budget::Month.new(budget, Date.new(2026, 10, 1))

        expect(last_month.envelopes.find { |line| line.envelope.name == "Old gym" })
          .to have_attributes(carried_over: 0, assigned: 40, spent: 40, available: 0)
        expect(this_month.envelopes.map { |line| line.envelope.name }).not_to include("Old gym")
        expect(this_month.archived_envelopes.map(&:name)).to eq([ "Old gym" ])
      end

      it "is left unarchived when the developer has unarchived it" do
        budget.envelopes.archived.sole.unarchive

        run_seeds

        expect(budget.envelopes.archived).to be_empty
      end
    end

    it "changes nothing when it's run again" do
      run_seeds

      expect { run_seeds }.not_to change {
        [ Budget::SpendLink.count, Budget::Spend.count, Budget::BankTransaction.where.not(ignored_at: nil).count, User.count, Budget.count, Budget::Envelope.count, Budget::Deposit.count, Budget::Assignment.count, Budget::Spend.count,
          Budget::Refund.count, Budget::EnvelopeReallocation.count, Budget::ReadyToAssignReallocation.count, Budget::CsvFormat.count, Budget::Account.count, Budget::Import.count, Budget::BankTransaction.count,
          Budget::FilingRule.count, Budget::BankConnection.count ]
      }
    end

    it "leaves a Spend the developer has changed" do
      run_seeds
      spend = Budget::Spend.order(:date, :id).last
      spend.update!(amount: 1)

      run_seeds

      expect(spend.reload.amount).to eq(1)
    end

    it "leaves a Refund the developer has changed" do
      run_seeds
      refund = Budget::Refund.find_by!(description: "Loblaws return")
      refund.update!(amount: 1)

      run_seeds

      expect(refund.reload.amount).to eq(1)
    end

    it "leaves a Reallocation the developer has changed" do
      run_seeds
      reallocation = Budget::EnvelopeReallocation.sole
      reallocation.update!(amount: 1)

      run_seeds

      expect(reallocation.reload.amount).to eq(1)
      expect(Budget::EnvelopeReallocation.count).to eq(1)
    end

    it "leaves a Reallocation to Ready to Assign the developer has changed" do
      run_seeds
      reallocation = Budget::ReadyToAssignReallocation.sole
      reallocation.update!(amount: 1)

      run_seeds

      expect(reallocation.reload.amount).to eq(1)
      expect(Budget::ReadyToAssignReallocation.count).to eq(1)
    end

    it "leaves an Assigned amount the developer has changed" do
      travel_to Time.utc(2026, 10, 15, 16)
      run_seeds
      assignment = Budget::Envelope.find_by!(name: "Groceries").assignments.find_by!(month: Date.new(2026, 10, 1))
      assignment.update!(amount: 1)

      run_seeds

      expect(assignment.reload.amount).to eq(1)
    end

    it "leaves a Deposit the developer has changed" do
      run_seeds
      paycheck = Budget::Deposit.order(:date).last
      paycheck.update!(amount: 1)

      run_seeds

      expect(paycheck.reload.amount).to eq(1)
    end

    it "leaves a starting balance the developer has changed" do
      run_seeds
      envelope = Budget::Envelope.find_by!(name: "Groceries")
      envelope.update!(starting_balance: 1)

      run_seeds

      expect(envelope.reload.starting_balance).to eq(1)
    end
  end
end
