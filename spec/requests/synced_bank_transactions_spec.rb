require "rails_helper"

# Bank transactions a sync brought in from Splitwise (ADR 0016), as the Bank transactions page and an Account's page show them: filed, split and ignored like any
# other, with a "Deleted in Splitwise" flag on one that went from Splitwise, and "Doesn't add up" on a filed one that changed since it was filed.
RSpec.describe "Bank transactions from Splitwise", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, :synced, budget: budget, name: "Roommates") }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  before do
    travel_to Time.utc(2026, 10, 14, 16)
    sign_in_as budget.user
  end

  def rows
    css_select("main ul.list li").map { |row| row.text.squish }
  end

  def row_for(description)
    css_select("main ul.list li").find { |row| row.text.include?(description) } or raise "no row for #{description}"
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  def unfiled_count_text
    css_select("nav[aria-label=Sections] li a").find { |link| link.text.include?("unfiled") }&.text&.squish
  end

  # A bank transaction of the Splitwise Account, as a sync makes it.
  def expense(description, amount, *traits, date: Date.new(2026, 10, 3))
    create(:budget_bank_transaction, *traits, account: account, description: description, amount: amount, date: date).reload
  end

  # Filed as one record of its whole amount: a Refund to Groceries for money in, a Spend from it for money out.
  def file(transaction, kind: transaction.amount.positive? ? "refund" : "spend")
    entry = Budget::Filing::Entry.new(bank_transaction: transaction, drafts: [ Budget::Filing::Draft.for(transaction, kind: kind, envelope_id: groceries.id) ])
    expect(Budget::Filing.new(budget).file([ entry ])).to be(true)
    transaction.reload
  end

  describe "one that went from Splitwise, and was never filed or ignored" do
    let!(:gone) { expense("Deleted dinner", -30, :removed) }
    let!(:kept) { expense("Dinner at Nonna's", 50) }

    it "leaves the Unfiled state, and the count of unfiled bank transactions in the header" do
      get bank_transactions_path(filter: { state: "unfiled" })

      expect(rows.join(" ")).to include("Dinner at Nonna's")
      expect(rows.join(" ")).not_to include("Deleted dinner")
      expect(unfiled_count_text).to eq("1 unfiled")
    end

    it "is still in the All state, in words, and can't be opened to be filed" do
      get bank_transactions_path(filter: { date_from: "2026-10-01", date_to: "2026-10-31" })

      row = row_for("Deleted dinner")
      expect(row.css(".badge").map { |badge| badge.text.squish }).to eq([ "Deleted in Splitwise" ])
      expect(row.css("a").map { |link| link["href"] }).to be_empty
      expect(row_for("Dinner at Nonna's").css("a").first["href"]).to eq(new_bank_transaction_filing_path(kept, from: "bank_transactions", filter: { date_from: "2026-10-01", date_to: "2026-10-31" }))
    end

    it "is on the Account's page, flagged the same way, which lists every bank transaction in every state" do
      get account_path(account)

      expect(row_for("Deleted dinner").css(".badge").map { |badge| badge.text.squish }).to eq([ "Deleted in Splitwise" ])
      expect(row_for("Dinner at Nonna's").css(".badge").map { |badge| badge.text.squish }).to eq([ "Unfiled" ])
    end

    it "isn't offered by File and next, or File N as guessed, and isn't reviewed", :aggregate_failures do
      earlier = expense("Earlier lunch", -12, date: Date.new(2026, 10, 1))
      current = expense("Current lunch", -14, date: Date.new(2026, 10, 3))
      gone.update!(date: Date.new(2026, 10, 2))

      expect(current.next_unfiled(scope: account.bank_transactions.where(id: [ earlier, current, gone ].map(&:id)))).to eq(earlier)

      get new_guessed_filing_path
      expect(response.body).not_to include("Deleted dinner")
    end

    it "is not filed by a crafted request, and nothing is made" do
      post bank_transaction_filing_path(gone), params: { filing: { records: { "0" => { kind: "spend", envelope_id: groceries.id, description: "Dinner", date: "2026-10-03", amount: "30", notes: "" } } } }

      expect(flash[:alert]).to eq("This bank transaction was deleted in Splitwise, so it can't be filed.")
      expect(Budget::Spend.count).to eq(0)
      expect(gone.reload).not_to be_filed
    end
  end

  describe "one that's filed" do
    let!(:dinner) { file(expense("Dinner at Nonna's", 50)) }

    it "says nothing's wrong while it adds up and is still in Splitwise" do
      get account_path(account)

      row = row_for("Dinner at Nonna's")
      expect(row.css(".badge").map { |badge| badge.text.squish }).to eq([ "Filed" ])
      expect(row.text).not_to include("Doesn't add up")
    end

    it "says it doesn't add up when its amount changed, with by how much, and blocks nothing" do
      dinner.update!(amount: 60)

      get account_path(account)

      row = row_for("Dinner at Nonna's")
      expect(row.css(".badge").map { |badge| badge.text.squish }).to eq([ "Filed", "Doesn't add up" ])
      expect(row.text.squish).to include("Its records add up to $50.00, not $60.00.")
    end

    it "says so when only its sign changed, since a Refund can't stand for money out, though the size is the same" do
      dinner.update!(amount: -50)

      get account_path(account)

      row = row_for("Dinner at Nonna's")
      expect(row.css(".badge").map { |badge| badge.text.squish }).to eq([ "Filed", "Doesn't add up" ])
      expect(row.text.squish).to include("It's now money out, but it was filed as a Refund.")
      expect(row.text.squish).not_to include("add up to $50.00, not $50.00")
    end

    it "says so for a Spend that's now money in, and a Deposit and a Refund that are now money out" do
      spent = file(expense("Weekly shop", -40))
      spent.update!(amount: 40)
      split = expense("Paycheck share", 100)
      entries = [ Budget::Filing::Entry.new(bank_transaction: split, drafts: [ Budget::Filing::Draft.for(split, kind: "deposit", amount: "60"), Budget::Filing::Draft.for(split, kind: "refund", envelope_id: groceries.id, amount: "40") ]) ]
      expect(Budget::Filing.new(budget).file(entries)).to be(true)
      split.update!(amount: -100)

      get account_path(account)

      expect(row_for("Weekly shop").text.squish).to include("It's now money in, but it was filed as a Spend.")
      expect(row_for("Paycheck share").text.squish).to include("It's now money out, but it was filed as a Deposit and a Refund.")
    end

    it "says it was deleted in Splitwise beside Un-file, and keeps its records until it's un-filed" do
      dinner.update!(removed_at: Time.current)

      get account_path(account)

      row = row_for("Dinner at Nonna's")
      expect(row.css(".badge").map { |badge| badge.text.squish }).to eq([ "Filed", "Deleted in Splitwise" ])
      expect(row.text.squish).to include("Un-file it, or keep its records.")
      expect(row.css("button").map { |button| button.text.squish }).to eq([ "Un-file" ])
      expect(row.css("a").map { |link| link.text.squish }).to eq([ "Refund to Groceries" ])
      expect(Budget::Refund.count).to eq(1)
    end

    it "is un-filed from there, which deletes its records and leaves it deleted in Splitwise, and not unfiled" do
      dinner.update!(removed_at: Time.current)

      delete bank_transaction_filing_path(dinner), params: { from: "account" }

      expect(flash[:notice]).to eq("Bank transaction unfiled.")
      expect(Budget::Refund.count).to eq(0)
      expect(dinner.reload.state).to eq(:removed)
      expect(Budget::BankTransaction.unfiled).to be_empty
    end

    it "can say both when the amount changed and it was deleted" do
      dinner.update!(amount: 55, removed_at: Time.current)

      get account_path(account)

      expect(row_for("Dinner at Nonna's").css(".badge").map { |badge| badge.text.squish }).to eq([ "Filed", "Doesn't add up", "Deleted in Splitwise" ])
    end
  end

  describe "a settle-up, which arrives ignored" do
    it "says it's ignored, and can be un-ignored" do
      payment = expense("Jane paid me back", 50, :ignored)

      get bank_transactions_path(filter: { state: "ignored", date_from: "2026-10-01", date_to: "2026-10-31" })

      row = row_for("Jane paid me back")
      expect(row.css(".badge").map { |badge| badge.text.squish }).to eq([ "Ignored" ])
      expect(row.css("button").map { |button| button.text.squish }).to eq([ "Un-ignore" ])

      delete bank_transaction_ignore_path(payment)

      expect(payment.reload).to be_unfiled
    end

    it "says it was deleted in Splitwise too, when it was" do
      expense("Jane paid me back", 50, :ignored, :removed)

      get account_path(account)

      expect(row_for("Jane paid me back").css(".badge").map { |badge| badge.text.squish }).to eq([ "Ignored", "Deleted in Splitwise" ])
    end
  end

  describe "the number of queries" do
    it "is the same for a page of a few of them, in every state, as for a lot" do
      make_some = lambda do |count|
        count.times do |n|
          transaction = expense("Dinner #{n}", (n.even? ? 50 : -50), date: Date.new(2026, 10, 1 + (n % 20)))
          case n % 4
          when 0 then file(transaction)
          when 1 then transaction.update!(ignored_at: Time.current, removed_at: Time.current)
          when 2 then transaction.update!(removed_at: Time.current)
          end
        end
      end

      make_some.call(4)
      get account_path(account)
      few = count_queries { get account_path(account) }
      get bank_transactions_path
      few_page = count_queries { get bank_transactions_path }

      make_some.call(20)
      many = count_queries { get account_path(account) }
      many_page = count_queries { get bank_transactions_path }

      expect(many).to eq(few)
      expect(many_page).to eq(few_page)
    end
  end
end
