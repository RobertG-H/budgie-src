require "rails_helper"

# A record that a bank transaction was filed as is an ordinary Deposit, Spend or Refund (ADR 0002): it shows in the budget like any
# other, and is edited and deleted like one. Only its edit page says where it came from, since deleting it unfiles the bank
# transaction.
RSpec.describe "Records filed from bank transactions", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

  before { sign_in_as budget.user }

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  let!(:money_out) { create(:budget_bank_transaction, account: account, description: "COSTCO #123", date: Date.new(2026, 9, 12), amount: -100) }
  let!(:money_in) { create(:budget_bank_transaction, account: account, description: "ACME PAYROLL", date: Date.new(2026, 9, 30), amount: 3000) }
  let!(:spend) { create(:budget_spend_link, bank_transaction: money_out, spend: create(:budget_spend, envelope: groceries, description: "Costco run", date: Date.new(2026, 9, 12), amount: 100)).spend }
  let!(:deposit) { create(:budget_deposit_link, bank_transaction: money_in, deposit: create(:budget_deposit, budget: budget, description: "Paycheck", date: Date.new(2026, 9, 30), amount: 3000)).deposit }
  let!(:refund) do
    refunded = create(:budget_bank_transaction, account: account, description: "STORE CREDIT", date: Date.new(2026, 9, 20), amount: 12.25)
    create(:budget_refund_link, bank_transaction: refunded, refund: create(:budget_refund, envelope: groceries, description: "Return", date: Date.new(2026, 9, 20), amount: 12.25)).refund
  end

  describe "the edit page" do
    it "says it was filed from a bank transaction, in which Account, and that deleting it unfiles that bank transaction" do
      {
        spend => edit_spend_path(spend, month: "2026-09", from: "month"),
        deposit => edit_deposit_path(deposit, month: "2026-09", from: "month"),
        refund => edit_refund_path(refund, month: "2026-09", from: "month")
      }.each do |record, path|
        get path

        expect(response).to have_http_status(:ok)
        expect(visible_text).to include("Filed from a bank transaction in Chequing,", "Deleting it un-files that bank transaction.")
        assert_select "main a[href='#{account_path(account)}']", text: "Chequing"
      end
    end

    it "names the bank transaction by its date and description as the bank gave it" do
      get edit_spend_path(spend, month: "2026-09")

      expect(visible_text).to include("Sep 12, 2026, COSTCO #123")
    end

    it "says nothing of the kind about a record that was typed in" do
      typed = create(:budget_spend, envelope: groceries, description: "Typed in", date: Date.new(2026, 9, 14), amount: 5)

      get edit_spend_path(typed, month: "2026-09")

      expect(visible_text).not_to include("bank transaction")
      assert_select "main a[href='#{account_path(account)}']", count: 0
    end
  end

  describe "deleting one" do
    it "deletes its link too, which leaves the bank transaction unfiled when it was the only record" do
      expect { delete spend_path(spend), params: { from: "month", month: "2026-09" } }.to change(Budget::SpendLink, :count).by(-1)

      expect(money_out.reload).to be_unfiled
      expect(response).to redirect_to(month_path("2026-09"))
    end

    it "does the same for a Deposit and a Refund" do
      delete deposit_path(deposit), params: { from: "month", month: "2026-09" }
      delete refund_path(refund), params: { from: "month", month: "2026-09" }

      expect(money_in.reload).to be_unfiled
      expect(Budget::RefundLink.count).to eq(0)
      expect(Budget::BankTransaction.unfiled.count).to eq(2)
    end

    it "leaves the others when a bank transaction was filed as several, which is then still filed, and flagged" do
      second = create(:budget_spend, envelope: groceries, description: "Second", date: Date.new(2026, 9, 12), amount: 40)
      create(:budget_spend_link, bank_transaction: money_out, spend: second)
      spend.update!(amount: 60)
      expect(money_out.reload).to be_adds_up

      delete spend_path(second), params: { from: "month", month: "2026-09" }

      expect(money_out.reload).to be_filed
      expect(money_out).not_to be_adds_up
    end
  end

  describe "changing one" do
    it "shows the flag on the Account's page when its amount stops the records adding up, and blocks nothing" do
      patch spend_path(spend), params: { spend: { amount: "90" }, from: "month", month: "2026-09" }

      expect(response).to redirect_to(month_path("2026-09"))
      expect(spend.reload.amount).to eq(90)

      get account_path(account)

      expect(visible_text).to include("Doesn't add up", "Its records add up to $90.00, not $100.00.")
    end

    it "doesn't flag a change to its description, or one that puts the amount back" do
      patch spend_path(spend), params: { spend: { description: "Costco, again" }, from: "month", month: "2026-09" }
      get account_path(account)
      expect(visible_text).not_to include("Doesn't add up")

      patch spend_path(spend), params: { spend: { amount: "80" }, from: "month", month: "2026-09" }
      patch spend_path(spend), params: { spend: { amount: "100" }, from: "month", month: "2026-09" }
      get account_path(account)

      expect(visible_text).not_to include("Doesn't add up")
    end
  end

  describe "the budget" do
    it "counts a filed Spend, Refund and Deposit like one typed in" do
      month = Budget::Month.new(budget, Date.new(2026, 9, 1))
      line = month.envelope_line(groceries.id)

      expect(line).to have_attributes(spent: 100, refunded: BigDecimal("12.25"))
      expect(month.ready_to_assign.deposited).to eq(3000)
    end
  end
end
