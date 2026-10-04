require "rails_helper"

RSpec.describe "The Unfiled list", type: :request do
  include FilingHistory

  let(:budget) { create(:budget, currency: "CAD") }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:visa) { create(:budget_account, budget: budget, name: "Visa") }
  let(:account) { chequing }

  before { sign_in_as budget.user }

  def rows
    css_select("main ul.list li").map { |row| row.text.squish }
  end

  describe "GET /unfiled" do
    it "lists every unfiled bank transaction across the Accounts, newest first, each with its Account, date, description and signed amount" do
      create(:budget_bank_transaction, account: chequing, date: Date.new(2026, 9, 2), description: "Loblaws", amount: -82.45)
      create(:budget_bank_transaction, account: visa, date: Date.new(2026, 9, 12), description: "Costco", amount: -100)
      create(:budget_bank_transaction, account: chequing, date: Date.new(2026, 8, 30), description: "Paycheck", amount: 2800)

      get unfiled_bank_transactions_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Unfiled · Budgie"
      assert_select "h1", text: "Unfiled"
      expect(rows).to eq([ "Sep 12, 2026 Costco Visa -$100.00", "Sep 2, 2026 Loblaws Chequing -$82.45", "Aug 30, 2026 Paycheck Chequing $2,800.00" ])
      assert_select "main ul.list li span.text-error", text: "-$100.00"
    end

    it "has none that are filed or ignored, and none of another budget's" do
      create(:budget_bank_transaction, account: chequing, description: "Unfiled one")
      create(:budget_bank_transaction, :filed, account: chequing, description: "Filed one")
      create(:budget_bank_transaction, :ignored, account: visa, description: "Ignored one")
      create(:budget_bank_transaction, description: "Someone else's")

      get unfiled_bank_transactions_path

      expect(rows.join(" ")).to include("Unfiled one")
      expect(rows.size).to eq(1)
    end

    it "opens the filing form from each, which comes back here" do
      bank_transaction = create(:budget_bank_transaction, account: chequing)

      get unfiled_bank_transactions_path

      assert_select "main ul.list li a.list-row[href='#{new_bank_transaction_filing_path(bank_transaction, from: "unfiled")}']"
    end

    it "says when everything has been dealt with" do
      create(:budget_bank_transaction, :filed, account: chequing)

      get unfiled_bank_transactions_path

      assert_select "main", text: /Every bank transaction has been filed or ignored/
    end

    it "shows 50 a page, newest first, with links to the older pages" do
      import = create(:budget_import, account: chequing)
      70.times { |n| create(:budget_bank_transaction, account: chequing, import: import, description: "Merchant #{n + 1}", date: Date.new(2026, 9, 30) - n) }

      get unfiled_bank_transactions_path

      expect(rows.size).to eq(50)
      expect(rows.first).to include("Merchant 1")
      assert_select "nav[aria-label=Pages] a[rel=next][href='#{unfiled_bank_transactions_path(page: 2)}']", text: "Older"

      get unfiled_bank_transactions_path(page: 2)

      expect(rows.size).to eq(20)
      assert_select "nav[aria-label=Pages] a[rel=prev]", text: "Newer"
    end

    it "runs the same number of queries however many bank transactions it shows, and across however many Accounts" do
      create(:budget_bank_transaction, account: chequing)
      get unfiled_bank_transactions_path
      few = count_queries { get unfiled_bank_transactions_path }

      imports = { chequing => create(:budget_import, account: chequing), visa => create(:budget_import, account: visa) }
      30.times { |n| create(:budget_bank_transaction, account: (account = n.even? ? chequing : visa), import: imports[account]) }
      many = count_queries { get unfiled_bank_transactions_path }

      expect(many).to eq(few)
    end

    it "requires sign-in" do
      delete session_path

      get unfiled_bank_transactions_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "Guesses" do
    let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
    let!(:household) { create(:budget_envelope, budget: budget, name: "Household") }

    it "shows each row's Guess, saying which bank transaction it was like, and nothing for a row with none" do
      filed("LOBLAWS #1234", groceries)
      filed("ACME PAYROLL SEP", amount: 2800)
      unfiled("LOBLAWS #5678", date: Date.new(2026, 10, 3))
      unfiled("ACME PAYROLL OCT", amount: 2800, date: Date.new(2026, 10, 2))
      unfiled("SHELL OIL #55", date: Date.new(2026, 10, 1))

      get unfiled_bank_transactions_path

      expect(rows).to eq([ "Oct 3, 2026 LOBLAWS #5678 Chequing Guess: like LOBLAWS #1234 → Groceries -$20.00",
                           "Oct 2, 2026 ACME PAYROLL OCT Chequing Guess: like ACME PAYROLL SEP → Deposit $2,800.00",
                           "Oct 1, 2026 SHELL OIL #55 Chequing -$20.00" ])
    end

    it "has no Guess for a row that an active Filing rule fits, but has one when the rule is for an archived envelope" do
      filed("LOBLAWS #1234", groceries)
      filed("COSTCO #12", household)
      create(:budget_filing_rule, budget: budget, envelope: household, text: "costco")
      closed = create(:budget_envelope, budget: budget, name: "Closed")
      create(:budget_filing_rule, budget: budget, envelope: closed, text: "loblaws")
      closed.archive!
      unfiled("COSTCO #99", date: Date.new(2026, 10, 3))
      unfiled("LOBLAWS #5678", date: Date.new(2026, 10, 2))

      get unfiled_bank_transactions_path

      expect(rows).to eq([ "Oct 3, 2026 COSTCO #99 Chequing -$20.00", "Oct 2, 2026 LOBLAWS #5678 Chequing Guess: like LOBLAWS #1234 → Groceries -$20.00" ])
    end

    it "still opens the filing form from a row with a Guess, which starts on it" do
      filed("LOBLAWS #1234", groceries)
      row = unfiled("LOBLAWS #5678")

      get unfiled_bank_transactions_path

      assert_select "main ul.list li a.list-row[href='#{new_bank_transaction_filing_path(row, from: "unfiled")}']"
    end

    it "offers File N as guessed, N being the rows on the page that have a Guess, and only when there are some" do
      filed("LOBLAWS #1234", groceries)
      unfiled("LOBLAWS #5678")
      second = unfiled("LOBLAWS #6789")
      unfiled("SHELL OIL #55")

      get unfiled_bank_transactions_path

      assert_select "main a.btn[href='#{new_guessed_filing_path}']", text: "File 2 as guessed"

      second.update!(ignored_at: Time.current)
      get unfiled_bank_transactions_path

      assert_select "main a.btn[href='#{new_guessed_filing_path}']", text: "File 1 as guessed"
    end

    it "offers nothing to file as guessed when no row has a Guess" do
      unfiled("SHELL OIL #55")

      get unfiled_bank_transactions_path

      assert_select "main a", text: /as guessed/, count: 0
    end

    it "counts and reviews only the page it's on, and the link goes to the same page of the review" do
      filed("LOBLAWS #1234", groceries)
      import = create(:budget_import, account: chequing)
      55.times { |n| create(:budget_bank_transaction, account: chequing, import: import, description: "LOBLAWS ##{n + 1}", date: Date.new(2026, 9, 30) - n) }

      get unfiled_bank_transactions_path
      assert_select "main a.btn[href='#{new_guessed_filing_path}']", text: "File 50 as guessed"

      get unfiled_bank_transactions_path(page: 2)
      assert_select "main a.btn[href='#{new_guessed_filing_path(page: 2)}']", text: "File 5 as guessed"
    end

    it "creates and changes nothing, by being shown" do
      filed("LOBLAWS #1234", groceries)
      row = unfiled("LOBLAWS #5678")

      expect { get unfiled_bank_transactions_path }
        .not_to change { [ Budget::Spend.count, Budget::SpendLink.count, Budget::FilingRule.count, row.reload.attributes ] }
      expect(row).to be_unfiled
    end

    it "runs the same number of queries for 5 rows as for a full page, and with 1 filed bank transaction as with 1,000" do
      filed("MERCHANT 3 1", groceries)
      create(:budget_filing_rule, budget: budget, envelope: household, text: "costco")
      5.times { |n| unfiled("MERCHANT #{n} #{n}", date: Date.new(2026, 10, 2)) }
      get unfiled_bank_transactions_path
      few_rows = count_queries { get unfiled_bank_transactions_path }

      import = create(:budget_import, account: chequing)
      45.times { |n| create(:budget_bank_transaction, account: chequing, import: import, description: (n.even? ? "MERCHANT #{n} #{n}" : "COSTCO ##{n}"), date: Date.new(2026, 9, 1) + (n % 28)) }
      many_rows = count_queries { get unfiled_bank_transactions_path }

      file_in_bulk(100...1000, household)
      many_filed = count_queries { get unfiled_bank_transactions_path }

      expect(many_rows).to eq(few_rows)
      expect(many_filed).to eq(few_rows)
    end
  end
end
