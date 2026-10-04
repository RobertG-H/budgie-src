require "rails_helper"

# "File N as guessed": after an Import, a page of Guesses that are right can be filed in one click, after a review list. It files through the same
# operation a person uses, makes no Filing rules, and files nothing without that click (ADR 0012).
RSpec.describe "Filing as guessed", type: :request do
  include FilingHistory

  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

  before do
    sign_in_as budget.user
    filed("LOBLAWS #1234", groceries)
    filed("COSTCO #12", household)
    filed("ACME PAYROLL SEP", amount: 2800)
    filed("LOBLAWS RETURN", groceries, amount: 18.75)
  end

  let!(:loblaws) { unfiled("LOBLAWS #5678", date: Date.new(2026, 10, 4)) }
  let!(:costco) { unfiled("COSTCO #99", amount: -100, date: Date.new(2026, 10, 3)) }
  let!(:payroll) { unfiled("ACME PAYROLL OCT", amount: 2800, date: Date.new(2026, 10, 2)) }
  let!(:return_row) { unfiled("LOBLAWS RETURN #88", amount: 9.5, date: Date.new(2026, 10, 1)) }
  let!(:shell) { unfiled("SHELL OIL #55", date: Date.new(2026, 9, 30)) }

  def rows
    css_select("main ul.list li").map { |row| row.text.squish }
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # What the review sends back for the rows it was shown, as a person ticks them: each id with the outcome that was reviewed.
  def reviewed(*bank_transactions)
    bank_transactions.to_h { |bank_transaction| [ bank_transaction.id.to_s, Budget::Guesser.new(budget).guess(bank_transaction).review_value ] }
  end

  def file_as_guessed(guessed, page: nil)
    post guessed_filing_path, params: { guessed: guessed, page: page }.compact
  end

  describe "GET /unfiled/guessed/new, the review" do
    it "lists the rows of the page that have a Guess, newest first, each ticked, with its Guess and what it would be filed as" do
      get new_guessed_filing_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "File as guessed · Budgie"
      assert_select "h1", text: "File as guessed"
      expect(rows).to eq([ "Oct 4, 2026 LOBLAWS #5678 Chequing Guess: like LOBLAWS #1234 → Groceries -$20.00",
                           "Oct 3, 2026 COSTCO #99 Chequing Guess: like COSTCO #12 → Household -$100.00",
                           "Oct 2, 2026 ACME PAYROLL OCT Chequing Guess: like ACME PAYROLL SEP → Deposit $2,800.00",
                           "Oct 1, 2026 LOBLAWS RETURN #88 Chequing Guess: like LOBLAWS RETURN → Refund to Groceries $9.50" ])
      assert_select "form[action='#{guessed_filing_path}'][method=post]" do
        assert_select "input[type=checkbox][name='guessed[#{loblaws.id}]'][value='spend:#{groceries.id}'][checked]"
        assert_select "input[type=checkbox][name='guessed[#{costco.id}]'][value='spend:#{household.id}'][checked]"
        assert_select "input[type=checkbox][name='guessed[#{payroll.id}]'][value='deposit:'][checked]"
        assert_select "input[type=checkbox][name='guessed[#{return_row.id}]'][value='refund:#{groceries.id}'][checked]"
        assert_select "input[type=checkbox]", count: 4
        assert_select "input[type=submit][value='File as guessed']"
      end
    end

    it "leaves out the rows with no Guess, which stay for the Unfiled list" do
      get new_guessed_filing_path

      expect(visible_text).not_to include("SHELL OIL")
      assert_select "input[type=checkbox][name='guessed[#{shell.id}]']", count: 0
    end

    it "says how many have a Guess, and that any can be left out, and Cancel goes back to the Unfiled list" do
      get new_guessed_filing_path

      expect(visible_text).to include("4 bank transactions on this page have a Guess. Untick any you'd rather file yourself.")
      assert_select "a.btn[href='#{unfiled_bank_transactions_path}']", text: "Cancel"
    end

    it "is for the page it was opened from, and goes back to it" do
      import = create(:budget_import, account: account)
      50.times { |n| create(:budget_bank_transaction, account: account, import: import, description: "SHELL OIL ##{n}", date: Date.new(2026, 10, 10) - (n % 5)) }

      get new_guessed_filing_path
      expect(visible_text).to include("None of the bank transactions on this page has a Guess.")

      get new_guessed_filing_path(page: 2)

      expect(rows.size).to eq(4)
      assert_select "input[type=hidden][name=page][value='2']"
      assert_select "a.btn[href='#{unfiled_bank_transactions_path(page: 2)}']", text: "Cancel"
    end

    it "says so when no row on the page has a Guess, and goes back, and offers nothing to file" do
      Budget::BankTransaction.where(id: [ loblaws, costco, payroll, return_row ]).update_all(ignored_at: Time.current)

      get new_guessed_filing_path

      expect(response).to have_http_status(:ok)
      expect(visible_text).to include("None of the bank transactions on this page has a Guess.")
      assert_select "a.btn[href='#{unfiled_bank_transactions_path}']", text: "Back to Unfiled"
      assert_select "form input[type=submit]", count: 0
    end

    it "has no Guess for a row that an active Filing rule fits" do
      create(:budget_filing_rule, budget: budget, envelope: household, text: "costco")

      get new_guessed_filing_path

      expect(visible_text).not_to include("COSTCO #99")
    end

    it "creates and changes nothing, by being shown" do
      expect { get new_guessed_filing_path }
        .not_to change { [ Budget::Spend.count, Budget::Refund.count, Budget::Deposit.count, Budget::FilingRule.count, Budget::BankTransaction.unfiled.count ] }
    end

    it "runs the same number of queries however many rows it shows and however much has been filed" do
      get new_guessed_filing_path
      few = count_queries { get new_guessed_filing_path }

      import = create(:budget_import, account: account)
      40.times { |n| create(:budget_bank_transaction, account: account, import: import, description: "COSTCO ##{n}", date: Date.new(2026, 9, 1) + (n % 28)) }
      file_in_bulk(0...300, household)
      many = count_queries { get new_guessed_filing_path }

      expect(many).to eq(few)
    end

    it "requires sign-in" do
      delete session_path

      get new_guessed_filing_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /unfiled/guessed, filing them" do
    it "files every row sent as it was reviewed: Spends, a Deposit and a Refund, each of the bank transaction's whole amount as the bank gave it" do
      expect { file_as_guessed(reviewed(loblaws, costco, payroll, return_row)) }
        .to change(Budget::Spend, :count).by(2).and change(Budget::Deposit, :count).by(1).and change(Budget::Refund, :count).by(1)

      expect(loblaws.reload.spend_links.sole.spend).to have_attributes(envelope: groceries, description: "LOBLAWS #5678", date: Date.new(2026, 10, 4), amount: 20, notes: "")
      expect(costco.reload.spend_links.sole.spend).to have_attributes(envelope: household, description: "COSTCO #99", amount: 100)
      expect(payroll.reload.deposit_links.sole.deposit).to have_attributes(description: "ACME PAYROLL OCT", date: Date.new(2026, 10, 2), month: Date.new(2026, 10, 1), amount: 2800)
      expect(return_row.reload.refund_links.sole.refund).to have_attributes(envelope: groceries, description: "LOBLAWS RETURN #88", amount: BigDecimal("9.5"))
      expect([ loblaws, costco, payroll, return_row ].map { |row| row.reload.filed? }).to all(be(true))
    end

    it "goes back to the page it was reviewed from, saying how many were filed" do
      file_as_guessed(reviewed(loblaws, costco), page: 3)

      expect(response).to redirect_to(unfiled_bank_transactions_path(page: 3))
      follow_redirect!
      expect(response.body).to include("2 bank transactions filed as guessed.")
    end

    it "says 1 bank transaction when it's one, and goes to the first page without a page" do
      file_as_guessed(reviewed(loblaws))

      expect(response).to redirect_to(unfiled_bank_transactions_path)
      expect(flash[:notice]).to eq("1 bank transaction filed as guessed.")
    end

    it "makes no Filing rule, and what it files has no rule noted, because a Guess isn't a rule" do
      expect { file_as_guessed(reviewed(loblaws, costco, payroll, return_row)) }.not_to change(Budget::FilingRule, :count)

      expect([ loblaws, costco, payroll, return_row ].map { |row| row.reload.filing_rule_id }).to all(be_nil)
      expect([ loblaws, costco, payroll, return_row ].map { |row| row.filed_by_rule }).to all(be_nil)
    end

    it "files only the rows that were ticked, and leaves the rest as they were, with no Guess or not" do
      expect { file_as_guessed(reviewed(loblaws)) }.to change(Budget::Spend, :count).by(1)

      expect([ costco, payroll, return_row, shell ].map { |row| row.reload.unfiled? }).to all(be(true))
    end

    it "never files a row that has no Guess unless it's sent, and what's sent is filed as it was reviewed, so a row nothing was like stays unfiled" do
      file_as_guessed(reviewed(loblaws, costco))

      expect(shell.reload).to be_unfiled
    end

    it "files what was reviewed even if the Guess has changed since, so nothing is filed that wasn't seen" do
      reviewed_outcomes = reviewed(loblaws)
      filed("LOBLAWS #7777", household)
      filed("LOBLAWS #7778", household)
      expect(Budget::Guesser.new(budget).guess(loblaws).envelope_id).to eq(household.id)

      file_as_guessed(reviewed_outcomes)

      expect(loblaws.reload.spend_links.sole.spend.envelope).to eq(groceries)
    end

    it "refuses it all when an envelope has been archived since the review, as filing by hand would, and files nothing" do
      reviewed_outcomes = reviewed(loblaws, costco)
      household.update!(archived_at: Time.current)

      expect { file_as_guessed(reviewed_outcomes) }.not_to change { [ Budget::Spend.count, Budget::SpendLink.count ] }

      expect(response).to redirect_to(new_guessed_filing_path)
      expect(flash[:alert]).to eq("Nothing was filed. COSTCO #99: Envelope is archived.")
      expect([ loblaws, costco ].map { |row| row.reload.unfiled? }).to all(be(true))
    end

    it "refuses it all when a row has been filed since the review, saying which, and files nothing" do
      reviewed_outcomes = reviewed(loblaws, costco)
      create(:budget_spend_link, bank_transaction: costco, spend: create(:budget_spend, envelope: groceries, date: costco.date, amount: 100))

      expect { file_as_guessed(reviewed_outcomes) }.not_to change(Budget::SpendLink, :count)

      expect(flash[:alert]).to eq("Nothing was filed. COSTCO #99: This bank transaction is already filed.")
      expect(loblaws.reload).to be_unfiled
    end

    it "refuses a kind that doesn't suit the money, and an envelope that isn't the budget's, like the form does" do
      other_envelope = create(:budget_envelope, name: "Someone else's")

      expect { file_as_guessed({ loblaws.id.to_s => "deposit:" }) }.not_to change(Budget::Spend, :count)
      expect(flash[:alert]).to eq("Nothing was filed. LOBLAWS #5678: Kind must be Spend, since the money went out.")

      expect { file_as_guessed({ loblaws.id.to_s => "spend:#{other_envelope.id}" }) }.not_to change(Budget::Spend, :count)
      expect(flash[:alert]).to eq("Nothing was filed. LOBLAWS #5678: Envelope can't be blank.")

      expect { file_as_guessed({ loblaws.id.to_s => "nonsense" }) }.not_to change(Budget::Spend, :count)
      expect(flash[:alert]).to start_with("Nothing was filed. LOBLAWS #5678: ")
      expect(loblaws.reload).to be_unfiled
    end

    it "is a 404 for another user's bank transaction, which is never filed, and files nothing" do
      others = create(:budget_bank_transaction, description: "LOBLAWS #5678").reload

      expect { file_as_guessed({ loblaws.id.to_s => "spend:#{groceries.id}", others.id.to_s => "spend:#{groceries.id}" }) }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:not_found)
      expect([ loblaws, others ].map { |row| row.reload.unfiled? }).to all(be(true))
    end

    it "asks for at least one when nothing was ticked, and files nothing" do
      expect { post guessed_filing_path }.not_to change(Budget::Spend, :count)

      expect(response).to redirect_to(new_guessed_filing_path)
      expect(flash[:alert]).to eq("Choose at least one bank transaction to file.")
    end

    it "files each once when it's sent twice, since the second finds them filed" do
      guessed = reviewed(loblaws, costco)
      file_as_guessed(guessed)

      expect { file_as_guessed(guessed) }.not_to change(Budget::Spend, :count)

      expect(flash[:alert]).to start_with("Nothing was filed.")
      expect(loblaws.reload.spend_links.count).to eq(1)
    end

    it "makes the same number of queries for 2 rows as for 40" do
      two = reviewed(loblaws, costco)
      few = count_queries { file_as_guessed(two) }

      import = create(:budget_import, account: account)
      rows = Array.new(40) { |n| create(:budget_bank_transaction, account: account, import: import, description: "COSTCO ##{n + 100}", date: Date.new(2026, 9, 1) + (n % 28)).reload }
      guessed = rows.to_h { |row| [ row.id.to_s, "spend:#{household.id}" ] }
      many = count_queries { file_as_guessed(guessed) }

      expect(many).to eq(few)
      expect(rows.map { |row| row.reload.filed? }).to all(be(true))
    end

    it "requires sign-in" do
      guessed = reviewed(loblaws)
      delete session_path

      file_as_guessed(guessed)

      expect(response).to redirect_to(sign_in_path)
      expect(loblaws.reload).to be_unfiled
    end
  end

  describe "Undo" do
    it "still deletes what was filed as guessed, with the rest of the latest Import" do
      csv_format = create(:budget_csv_format, budget: budget)
      import = account.imports.build(csv_format: csv_format, file_name: "oct.csv")
      expect(import.run("2026-09-05,LOBLAWS #9001,-30.00\n2026-09-06,COSTCO #9002,-45.00\n")).to be(true)
      imported = Budget::BankTransaction.where(import_id: import.id).order(:id).reload.to_a

      file_as_guessed(reviewed(*imported))
      expect(imported.map { |row| row.reload.filed? }).to all(be(true))

      expect { delete import_path(import) }.to change(Budget::Spend, :count).by(-2).and change { Budget::BankTransaction.where(id: imported).count }.by(-2)

      expect(response).to redirect_to(account_path(account))
      expect(Budget::SpendLink.where(bank_transaction_id: imported.map(&:id))).to be_empty
    end
  end
end
