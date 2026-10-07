require "rails_helper"

# An Account that's synced from a connection, such as Splitwise (ADR 0016), takes no CSV Import: not in the UI and not from a crafted request. It's
# still an Account like any other to list, rename, keep Filing rules off for and delete.
RSpec.describe "Accounts that are synced", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:csv_format) { create(:budget_csv_format, budget: budget, name: "Plain") }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:splitwise_account) { create(:budget_account, :synced, budget: budget, name: "Roommates") }
  let(:csv) { "2026-10-01,Paycheck,2800.00\n" }

  before { sign_in_as budget.user }

  def uploaded(text = csv)
    Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "october.csv")
  end

  describe "the Accounts page" do
    it "offers Connect Splitwise beside New account, where Splitwise is set up" do
      get accounts_path

      assert_select "main a.btn[href='#{new_splitwise_connection_path}']", text: "Connect Splitwise"
      assert_select "main a.btn.btn-primary[href='#{new_account_path}']", text: "New account"
    end

    it "doesn't offer it where Splitwise isn't set up, since it has no client id" do
      Splitwise.client = SplitwiseFake.new(configured: false)

      get accounts_path

      assert_select "a", text: "Connect Splitwise", count: 0
      assert_select "main a.btn.btn-primary[href='#{new_account_path}']", text: "New account"
    end

    it "says which Accounts are synced, and how many bank transactions each has" do
      create_list(:budget_bank_transaction, 2, account: splitwise_account)

      get accounts_path

      assert_select "main ul.list li a[href='#{account_path(splitwise_account)}'] span.block", text: "Synced from Splitwise. 2 bank transactions"
      assert_select "main ul.list li a[href='#{account_path(chequing)}'] span.block", text: "No bank transactions yet."
    end

    it "is still one list, whatever the Accounts are synced from, with the same number of queries for one as for many" do
      get accounts_path # Loads whatever the first request does once.
      few = count_queries { get accounts_path }

      5.times { create(:budget_account, :synced, budget: budget) }
      many = count_queries { get accounts_path }

      expect(many).to eq(few)
    end
  end

  describe "an Account's page" do
    it "has no Import, in its header or where it says it has no bank transactions yet" do
      get account_path(splitwise_account)

      expect(response).to have_http_status(:ok)
      assert_select "a", text: "Import", count: 1 # The header's own, which leads to the whole form.
      assert_select "main a[href='#{new_account_import_path(splitwise_account)}']", count: 0
      assert_select "main a.btn[href='#{edit_account_path(splitwise_account)}']", text: "Edit"
      assert_select "main .border-dashed", text: "No bank transactions yet. Expenses from Splitwise appear here once they're synced."
    end

    it "still has Import for an Account that isn't synced" do
      get account_path(chequing)

      assert_select "main a.btn.btn-primary[href='#{new_account_import_path(chequing)}']", text: "Import"
    end

    it "doesn't show a default CSV format, which a synced Account has no use for" do
      get account_path(splitwise_account)

      expect(response.body).not_to include("Default CSV format")
    end
  end

  describe "the Account's form" do
    it "leaves out the default CSV format for a synced Account, which has no files, and keeps the rest" do
      get edit_account_path(splitwise_account)

      assert_select "input[name='account[name]']"
      assert_select "select[name='account[default_csv_format_id]']", count: 0
      assert_select "input[type=checkbox][name='account[files_with_rules]']"
    end

    it "keeps it for an Account that isn't" do
      get edit_account_path(chequing)

      assert_select "select[name='account[default_csv_format_id]']"
    end

    it "can be renamed, and keeps its connection" do
      patch account_path(splitwise_account), params: { account: { name: "Roommates" } }

      expect(response).to redirect_to(account_path(splitwise_account))
      expect(splitwise_account.reload).to be_synced
      expect(splitwise_account.name).to eq("Roommates")
    end

    it "never takes its connection, or its external id, from the form" do
      other = create(:budget_bank_connection, budget: budget, login_id: "9999")

      patch account_path(splitwise_account), params: { account: { name: "Roommates", bank_connection_id: other.id, external_account_id: "9999" } }
      post accounts_path, params: { account: { name: "Sneaky", bank_connection_id: other.id, external_account_id: "9999" } }

      expect(splitwise_account.reload.bank_connection_id).not_to eq(other.id)
      expect(splitwise_account.external_account_id).not_to eq("9999")
      expect(budget.accounts.find_by!(name: "Sneaky")).not_to be_synced
    end
  end

  describe "deleting one" do
    it "asks first, and says its connection goes with it" do
      get edit_account_path(splitwise_account)

      question = css_select("form[data-turbo-confirm]").first["data-turbo-confirm"]
      expect(question).to eq("Delete the Roommates account? Its connection to Splitwise is removed with it.")
    end

    it "deletes it with its connection when it has no bank transactions" do
      expect { delete account_path(splitwise_account) }
        .to change(Budget::Account, :count).by(-1).and change(Budget::BankConnection, :count).by(-1)

      expect(response).to redirect_to(accounts_path)
      expect(flash[:notice]).to eq("Account deleted.")
    end

    it "deletes a disconnected one the same way" do
      splitwise_account.bank_connection.disconnect!

      expect { delete account_path(splitwise_account) }.to change(Budget::BankConnection, :count).by(-1)
    end

    it "can't be deleted while it has bank transactions, and keeps its connection" do
      create(:budget_bank_transaction, account: splitwise_account)

      expect { delete account_path(splitwise_account) }.not_to change { [ Budget::Account.count, Budget::BankConnection.count ] }

      expect(response).to redirect_to(account_path(splitwise_account))
      expect(flash[:alert]).to eq("This account can't be deleted because it has bank transactions.")
    end

    it "asks no question about a connection for an Account that has none" do
      get edit_account_path(chequing)

      expect(css_select("form[data-turbo-confirm]").first["data-turbo-confirm"]).to eq("Delete the Chequing account?")
    end
  end

  describe "importing into one" do
    it "isn't a form that's offered: GET /accounts/:id/imports/new goes back to the Account with why" do
      get new_account_import_path(splitwise_account)

      expect(response).to redirect_to(account_path(splitwise_account))
      expect(flash[:alert]).to eq("Roommates is synced from Splitwise, so it takes no Import.")
    end

    it "isn't done from a crafted request: POST /accounts/:id/imports imports nothing" do
      expect { post account_imports_path(splitwise_account), params: { import: { csv_format_id: csv_format.id, file: uploaded } } }
        .not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }

      expect(response).to redirect_to(account_path(splitwise_account))
      expect(flash[:alert]).to eq("Roommates is synced from Splitwise, so it takes no Import.")
    end

    it "isn't done from the whole form either, with the Account's id sent as it would be" do
      expect { post imports_path, params: { import: { csv_format_id: csv_format.id, account_id: splitwise_account.id, file: uploaded } } }
        .not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }

      expect(response).to redirect_to(account_path(splitwise_account))
    end

    it "is refused by the model whatever asks, with a reason on the Account" do
      import = Budget::Import.new(account: splitwise_account, csv_format: csv_format, file_name: "october.csv")

      expect { expect(import.run(csv)).to be(false) }.not_to change(Budget::BankTransaction, :count)

      expect(import.errors[:account]).to eq([ "is synced from Splitwise, so it takes no Import" ])
    end

    it "is still done into an Account that isn't synced" do
      expect { post account_imports_path(chequing), params: { import: { csv_format_id: csv_format.id, file: uploaded } } }.to change(Budget::Import, :count).by(1)
    end

    it "leaves it out of the whole form's Account select, and keeps the others" do
      get new_import_path

      assert_select "select[name='import[account_id]'] option", text: "Chequing"
      assert_select "select[name='import[account_id]'] option", text: "Roommates", count: 0
    end

    it "says there's no Account to import into when every Account is synced, with a way to add one" do
      chequing.destroy!

      get new_import_path

      expect(response.body).to include("You need an Account to import into.")
      assert_select "main a.btn[href='#{new_account_path}']", text: "New account"
    end

    it "gives the header's Import no file chooser when every Account is synced, since there's nothing to guess" do
      chequing.destroy!

      get accounts_path

      assert_select "[data-controller=import-picker]", count: 0
      assert_select "header a.btn[href='#{new_import_path}']", text: "Import"
    end

    it "gives the header's Import its file chooser once there's an Account that isn't" do
      get accounts_path

      assert_select "header [data-controller=import-picker]"
    end

    it "is never the Account a guessed Import goes into, even when a CSV format were its default" do
      splitwise_account.update_columns(default_csv_format_id: csv_format.id)

      expect { post import_guess_path, params: { import: { file: uploaded } } }.not_to change(Budget::Import, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("None of your Accounts has the Plain CSV format as its default, so choose the Account the file is for.")
    end

    it "is never the Account a guess finds, and doesn't make an Account that isn't certain look like it" do
      chequing.update!(default_csv_format: csv_format)
      splitwise_account.update_columns(default_csv_format_id: csv_format.id)

      expect { post import_guess_path, params: { import: { file: uploaded } } }.to change(chequing.imports, :count).by(1)

      expect(splitwise_account.reload.imports).to be_empty
    end
  end
end
