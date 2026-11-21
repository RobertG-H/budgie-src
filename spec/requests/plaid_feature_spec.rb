require "rails_helper"

# Plaid is turned on for chosen people (User#enable_feature!), since each Item the Trial gives is spent for good: where Plaid is set up, a person without it is exactly
# as if it weren't, through the same pages and words, and turning it off keeps everything they have, and turning it on again syncs from where it got to.
RSpec.describe "Connecting a bank, for a person who doesn't have Plaid turned on", type: :request do
  let(:user) { create(:user) }
  let(:budget) { create(:budget, currency: "CAD", user: user) }
  let(:connection) { create(:budget_bank_connection, :plaid, budget: budget, login_name: "TD Canada Trust", access_token: "bank-token") }
  let!(:chequing) { create(:budget_account, :plaid, budget: budget, bank_connection: connection, name: "TD Chequing", external_account_id: "acc-1") }

  before do
    sign_in_as user
    plaid.item("bank-token", accounts: [ plaid.account("acc-1", "TD Every Day Chequing") ])
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  it "doesn't offer Connect a bank on the Accounts page, and still offers Connect Splitwise" do
    get accounts_path

    assert_select "a[href='#{new_plaid_connection_path}']", count: 0
    assert_select "a[href='#{new_splitwise_connection_path}']", text: "Connect Splitwise"
  end

  it "offers none of the panel's actions on a bank's Account, which still says where it's synced from" do
    get account_path(chequing)

    expect(visible_text).to include("Synced from TD Canada Trust")
    assert_select "button", text: "Sync TD now", count: 0
    assert_select "button", text: "Disconnect TD", count: 0
    assert_select "a", text: "Reconnect", count: 0
    assert_select "a", text: "Choose accounts", count: 0
  end

  it "doesn't offer Connect TD again on a disconnected bank's Account" do
    connection.disconnect!

    get account_path(chequing)

    assert_select "a", text: "Connect TD again", count: 0
  end

  it "turns every way of connecting a bank away, with the alert a host without Plaid gives, without asking Plaid" do
    [ -> { get new_plaid_connection_path }, -> { post plaid_connection_path, params: { plaid_link: { public_token: "public-1" } } },
      -> { get plaid_choice_path }, -> { post plaid_choice_path, params: { plaid_choice: { accounts: {} } } } ].each do |request|
      instance_exec(&request)
      expect(response).to redirect_to(accounts_path)
      expect(flash[:alert]).to eq("Connecting a bank isn't set up here.")
    end

    expect(plaid.link_tokens + plaid.exchanges).to be_empty
  end

  it "turns Reconnect, Choose accounts and Disconnect away, without asking Plaid, and keeps the connection" do
    [ -> { get new_account_connection_reconnect_path(chequing) }, -> { post account_connection_reconnect_path(chequing) },
      -> { get new_account_connection_selection_path(chequing) }, -> { post account_connection_selection_path(chequing), params: { plaid_link: { accounts: {} } } },
      -> { delete account_connection_path(chequing) } ].each do |request|
      instance_exec(&request)
      expect(response).to redirect_to(account_path(chequing))
      expect(flash[:alert]).to eq("Connecting a bank isn't set up here.")
    end

    expect(plaid.update_link_tokens + plaid.account_requests + plaid.removals).to be_empty
    expect(connection.reload).to be_connected
  end

  it "turns Sync now away, without asking Plaid" do
    post account_connection_sync_path(chequing)

    expect(response).to redirect_to(accounts_path)
    expect(flash[:alert]).to eq("Plaid isn't set up here, so it can't be synced.")
    expect(plaid.transaction_requests).to be_empty
  end

  it "refuses to delete the connection's last Account, without asking Plaid, as where Plaid isn't set up" do
    delete account_path(chequing)

    expect(response).to redirect_to(account_path(chequing))
    expect(flash[:alert]).to eq("Plaid isn't set up here, so TD Chequing wasn't deleted and nothing was changed. Try again later.")
    expect(plaid.removals).to be_empty
    expect(chequing.reload.bank_connection).to eq(connection)
  end

  it "leaves Connecting a bank out of the User guide" do
    get guide_path

    expect(response).to have_http_status(:ok)
    headings = css_select("main section > h2").map { |heading| heading.text.squish }
    expect(headings).to eq(GuidesHelper::GUIDE_SECTIONS.values - [ "Connecting a bank" ])
    assert_select "main nav[aria-label='On this page'] a[href='#connecting-a-bank']", count: 0
    expect(visible_text).not_to include("Plaid", "Connect a bank")
  end

  describe "turning it off and on again" do
    let(:user) { create(:user, :plaid) }

    it "keeps the connection, its Accounts and their bank transactions and what they were filed as, and Sync now carries on from where it got to" do
      plaid.adds("bank-token", plaid.transaction("tx-1", account: "acc-1", description: "LOBLAWS"))
      post account_connection_sync_path(chequing)
      filed = chequing.bank_transactions.sole
      create(:budget_spend_link, bank_transaction: filed)
      cursor = connection.reload.sync_cursor

      user.disable_feature!(:plaid)
      plaid.adds("bank-token", plaid.transaction("tx-2", account: "acc-1", description: "COSTCO"))
      post account_connection_sync_path(chequing)

      expect(connection.reload).to be_connected
      expect(connection.sync_cursor).to eq(cursor)
      expect(chequing.reload.bank_connection).to eq(connection)
      expect(chequing.bank_transactions.sole).to be_filed

      user.enable_feature!(:plaid)
      plaid.transaction_requests.clear
      post account_connection_sync_path(chequing)

      expect(flash[:notice]).to start_with("Synced from TD Canada Trust: 1 new.")
      expect(plaid.transaction_requests).to eq([ [ "bank-token", cursor ] ])
      expect(chequing.bank_transactions.pluck(:description)).to contain_exactly("LOBLAWS", "COSTCO")
      expect(filed.reload).to be_filed
    end
  end
end
