require "rails_helper"

RSpec.describe "The Unfiled list", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:visa) { create(:budget_account, budget: budget, name: "Visa") }

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
end
