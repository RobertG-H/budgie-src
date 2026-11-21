require "rails_helper"

# Linking a bank's account onto an Account that's already there (ADR 0018, #158), on the choice page after Plaid Link, for Connect a bank and Choose accounts: the
# "Becomes" select offers each Account that takes CSV Imports and each of a disconnected bank's Accounts, a row that's a disconnected bank's Account starts on it,
# and a disconnected bank's Account offers "Connect TD again". The saving itself is in spec/services/connect_plaid_spec.rb and choose_plaid_accounts_spec.rb.
# Plaid is replaced by PlaidFake (spec/support/plaid.rb), and Link runs only in a browser, so what it would send is posted here as the plaid-link controller does.
RSpec.describe "Linking a bank's account onto an existing Account", type: :request do
  let(:budget) { create(:budget, currency: "CAD", user: create(:user, :plaid)) }
  let!(:csv_chequing) { create(:budget_account, budget: budget, name: "Chequing", default_csv_format: create(:budget_csv_format, budget: budget)) }

  around { |example| travel_to(Time.zone.local(2026, 11, 19, 12)) { example.run } }
  before do
    sign_in_as budget.user
    plaid.links("public-1", item_id: "item-1", institution_id: "ins_42", institution_name: "TD Canada Trust", accounts: [
      plaid.account("acc-1", "TD Every Day Chequing", mask: "4821", subtype: "checking"),
      plaid.account("acc-2", "TD ePremium Savings", mask: "1100", subtype: "savings")
    ])
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  def finish_link
    accounts = [ { id: "acc-1", name: "TD Every Day Chequing", mask: "4821", subtype: "checking" }, { id: "acc-2", name: "TD ePremium Savings", mask: "1100", subtype: "savings" } ]
    post plaid_connection_path, params: { plaid_link: { public_token: "public-1", institution_id: "ins_42", institution_name: "TD Canada Trust",
      accounts: accounts.each_with_index.to_h { |account, index| [ index.to_s, account ] } } }
  end

  def choose(rows)
    post plaid_choice_path, params: { plaid_choice: { accounts: rows } }
  end

  describe "the choice page" do
    it "offers each Account it can link onto in its own group, between A new Account and Leave out, starting at its latest bank transaction's date" do
      create(:budget_bank_transaction, account: csv_chequing, date: Date.new(2026, 11, 10))
      create(:budget_account, :plaid, budget: budget, name: "Live TD")
      finish_link

      get plaid_choice_path

      assert_select "select[name='plaid_choice[accounts][0][becomes]']" do
        assert_select "option", count: 3
        assert_select "option:first-child[value=new]", text: "A new Account"
        assert_select "optgroup[label='Link onto an existing Account'] option[value='link:#{csv_chequing.id}'][data-read-from='2026-11-10']", text: "Chequing"
        assert_select "option:last-child[value=leave]", text: "Leave out"
      end
      assert_select "[data-plaid-choice-target=panel][data-becomes=link]" do
        assert_select "input[type=date][name='plaid_choice[accounts][0][link_read_from]']"
      end
      expect(visible_text).to include("That day's bank transactions may come in twice. Ignore the ones you've already filed.")
      expect(visible_text).to include("It keeps its name, bank transactions and Filing rules, and takes no CSV Import once it's synced.")
    end

    it "has no group to link onto when there's no Account to link onto" do
      csv_chequing.destroy!
      finish_link

      get plaid_choice_path

      assert_select "optgroup", count: 0
      assert_select "[data-becomes=link]", count: 0
    end

    it "starts a row that's a disconnected bank's Account on linking onto it, from that Account's latest bank transaction" do
      old = create(:budget_bank_connection, :plaid, budget: budget, institution_id: "ins_42")
      old_savings = create(:budget_account, :plaid, budget: budget, bank_connection: old, name: "Old savings", external_name: "TD ePremium Savings", external_mask: "1100")
      create(:budget_bank_transaction, account: old_savings, date: Date.new(2026, 11, 2))
      old.disconnect!
      finish_link

      get plaid_choice_path

      assert_select "select[name='plaid_choice[accounts][0][becomes]'] option[selected][value=new]"
      assert_select "select[name='plaid_choice[accounts][1][becomes]'] option[selected][value='link:#{old_savings.id}']", text: "Old savings"
      assert_select "input[name='plaid_choice[accounts][1][link_read_from]'][value='2026-11-02']"
    end
  end

  describe "connecting with a linked Account" do
    before { finish_link }

    it "links onto the Account and goes to its page" do
      choose("0" => { becomes: "link:#{csv_chequing.id}", link_read_from: "2026-11-10" }, "1" => { becomes: "leave" })

      expect(response).to redirect_to(account_path(csv_chequing))
      expect(flash[:notice]).to eq("Connected TD Canada Trust. Its bank transactions arrive within the hour. Chequing keeps its bank transactions and is synced from TD Canada Trust now.")
      expect(csv_chequing.reload).to have_attributes(external_account_id: "acc-1", read_from: Date.new(2026, 11, 10), default_csv_format: nil)

      get account_path(csv_chequing)
      assert_select "main a[href='#{new_account_import_path(csv_chequing)}']", count: 0
      expect(visible_text).to include("Synced from TD Canada Trust, TD Every Day Chequing ••4821.")
    end

    it "refuses the same Account on two rows on the page, keeping the choices, and exchanges nothing" do
      choose("0" => { becomes: "link:#{csv_chequing.id}", link_read_from: "2026-11-10" }, "1" => { becomes: "link:#{csv_chequing.id}", link_read_from: "2026-11-10" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(visible_text).to include("TD ePremium Savings: Becomes is already chosen for another account on this page")
      assert_select "select[name='plaid_choice[accounts][1][becomes]'] option[selected][value='link:#{csv_chequing.id}']"
      expect(plaid.exchanges).to be_empty
    end
  end

  describe "Choose accounts" do
    let(:connection) { create(:budget_bank_connection, :plaid, budget: budget, access_token: "its-token") }
    let!(:td_chequing) { create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Chequing", external_account_id: "acc-1") }

    before do
      plaid.item("its-token", accounts: [ plaid.account("acc-1", "TD Every Day Chequing", mask: "4821"), plaid.account("acc-3", "TD Visa", mask: "7000") ])
      post account_connection_selection_path(td_chequing), params: { plaid_link: { accounts: {
        "0" => { id: "acc-1", name: "TD Every Day Chequing", mask: "4821" }, "1" => { id: "acc-3", name: "TD Visa", mask: "7000" } } } }
    end

    it "offers the Accounts to link onto, and links onto one" do
      get plaid_choice_path

      assert_select "select[name='plaid_choice[accounts][1][becomes]'] optgroup option", count: 1, text: "Chequing"

      choose("1" => { becomes: "link:#{csv_chequing.id}", link_read_from: "2026-11-01" })

      expect(response).to redirect_to(account_path(td_chequing))
      expect(flash[:notice]).to eq("Chequing keeps its bank transactions and is synced from TD Canada Trust now.")
      expect(csv_chequing.reload.bank_connection).to eq(connection)
    end
  end

  describe "a disconnected bank's Account" do
    let(:old) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust") }
    let!(:old_chequing) { create(:budget_account, :plaid, budget: budget, bank_connection: old, name: "Old chequing") }

    before { old.disconnect! }

    it "offers Connect TD again, which opens Connect a bank, and never Reconnect" do
      get account_path(old_chequing)

      assert_select "main a.btn-primary[href='#{new_plaid_connection_path}']", text: "Connect TD again"
      assert_select "main a", text: "Reconnect", count: 0
      expect(visible_text).to include("Connecting TD Canada Trust again can link this Account back onto it, keeping its bank transactions.")
    end

    it "doesn't offer it where Plaid isn't set up" do
      PlaidApi.client = PlaidFake.new(configured: false)

      get account_path(old_chequing)

      assert_select "main a", text: "Connect TD again", count: 0
    end

    it "still says it was synced from the disconnected bank on the Accounts list until it's linked again" do
      get accounts_path

      expect(visible_text).to include("Old chequing Was synced from TD Canada Trust, which was disconnected.")
    end
  end
end
