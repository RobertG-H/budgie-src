require "rails_helper"

RSpec.describe "Accounts", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:others_account) { create(:budget_account, name: "Someone else's") }

  before { sign_in_as budget.user }

  describe "GET /accounts" do
    it "lists the budget's Accounts alphabetically, and no one else's" do
      create(:budget_account, budget: budget, name: "visa")
      create(:budget_account, budget: budget, name: "Chequing")
      create(:budget_account, budget: budget, name: "Amex")
      others_account

      get accounts_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Accounts · Budgie"
      assert_select "h1", text: "Accounts"
      expect(css_select("main ul.list li a span.font-semibold").map(&:text)).to eq([ "Amex", "Chequing", "visa" ])
      expect(response.body).not_to include("Someone else")
    end

    it "links each to its page, and says how many bank transactions it has" do
      chequing = create(:budget_account, budget: budget, name: "Chequing")
      empty = create(:budget_account, budget: budget, name: "Visa")
      import = create(:budget_import, account: chequing)
      create_list(:budget_bank_transaction, 3, account: chequing, import: import)
      create(:budget_bank_transaction, account: create(:budget_account, budget: budget, name: "Amex"))

      get accounts_path

      assert_select "main ul.list li a[href='#{account_path(chequing)}']" do
        assert_select "span.font-semibold", text: "Chequing"
        assert_select "span.block", text: "3 bank transactions"
      end
      assert_select "main ul.list li a[href='#{account_path(empty)}'] span.block", text: "No bank transactions yet."
      assert_select "main ul.list li span.block", text: "1 bank transaction"
    end

    it "runs the same number of queries whatever the number of Accounts or bank transactions" do
      one = create(:budget_account, budget: budget)
      create(:budget_bank_transaction, account: one)
      get accounts_path # Loads whatever the first request does once.
      few = count_queries { get accounts_path }

      9.times { create(:budget_bank_transaction, account: create(:budget_account, budget: budget)) }
      create_list(:budget_bank_transaction, 20, account: one, import: one.imports.first)
      many = count_queries { get accounts_path }

      expect(many).to eq(few)
    end

    it "has a link to add one" do
      get accounts_path

      assert_select "main a.btn[href='#{new_account_path}']", text: "New account"
    end

    it "says when there are none, with a way to add one" do
      get accounts_path

      assert_select "main", text: /You don't have any accounts yet/
      assert_select "main .border-dashed a.btn[href='#{new_account_path}']", text: "New account"
    end

    it "requires sign-in" do
      delete session_path

      get accounts_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "GET /accounts/new" do
    it "shows a form for the name, which is all an Account has" do
      get new_account_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "New account · Budgie"
      assert_select "h1", text: "New account"
      assert_select "form[action='#{accounts_path}'][method=post]" do
        assert_select "label", text: "Name"
        assert_select "input[type=text][name='account[name]'][required]"
        assert_select "p", text: /Such as Chequing/
        assert_select "input[type=submit][value='Create Account']"
        assert_select "input:not([type=hidden]):not([type=submit])", count: 1
      end
      assert_select "a.btn[href='#{accounts_path}']", text: "Cancel"
    end
  end

  describe "POST /accounts" do
    it "adds an Account to the budget, and goes back to the list" do
      expect { post accounts_path, params: { account: { name: "Chequing" } } }.to change(budget.accounts, :count).by(1)

      expect(budget.accounts.sole.name).to eq("Chequing")
      expect(response).to redirect_to(accounts_path)
      follow_redirect!
      assert_select "[role=status]", text: "Account added."
    end

    it "refuses a blank name, or one that's used, in another case, keeping what was typed" do
      create(:budget_account, budget: budget, name: "Chequing")

      expect { post accounts_path, params: { account: { name: " " } } }.not_to change(Budget::Account, :count)
      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"

      expect { post accounts_path, params: { account: { name: "CHEQUING" } } }.not_to change(Budget::Account, :count)
      assert_select "[role=alert] li", text: "Name has already been taken"
      assert_select "input[name='account[name]'][value=CHEQUING][aria-invalid=true]"
    end

    it "never takes the budget from the params" do
      other = create(:budget)

      post accounts_path, params: { account: { name: "Chequing", budget_id: other.id } }

      expect(other.accounts).to be_empty
      expect(budget.accounts.count).to eq(1)
    end

    it "is a bad request without an account" do
      post accounts_path

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /accounts/:id" do
    let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }

    it "has the Account's name, a button to import into it, and one to edit it" do
      get account_path(account)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Chequing · Budgie"
      assert_select "h1", text: "Chequing"
      assert_select "main a.btn.btn-primary[href='#{new_account_import_path(account)}']", text: "Import"
      assert_select "main a.btn[href='#{edit_account_path(account)}']", text: "Edit"
    end

    it "lists its bank transactions newest first, each with its date, description and signed amount, money out red" do
      import = create(:budget_import, account: account)
      create(:budget_bank_transaction, account: account, import: import, date: Date.new(2026, 8, 30), description: "Paycheck", amount: 2800)
      create(:budget_bank_transaction, account: account, import: import, date: Date.new(2026, 9, 12), description: "Loblaws", amount: -82.45)
      create(:budget_bank_transaction, account: account, import: import, date: Date.new(2025, 12, 1), description: "Hydro", amount: -65.5)

      get account_path(account)

      rows = css_select("main ul.list li").map { |row| row.text.squish }
      expect(rows).to eq([ "Sep 12, 2026 Loblaws Unfiled -$82.45", "Aug 30, 2026 Paycheck Unfiled $2,800.00", "Dec 1, 2025 Hydro Unfiled -$65.50" ])
      assert_select "main ul.list li span.text-error", text: "-$82.45"
      assert_select "main ul.list li span.text-error", text: "$2,800.00", count: 0
    end

    describe "each bank transaction's state" do
      let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
      let!(:unfiled) { create(:budget_bank_transaction, account: account, date: Date.new(2026, 9, 4), description: "Unfiled one", amount: -20) }
      let!(:ignored) { create(:budget_bank_transaction, :ignored, account: account, date: Date.new(2026, 9, 3), description: "Ignored one", amount: -30) }
      let!(:filed) { create(:budget_bank_transaction, account: account, date: Date.new(2026, 9, 2), description: "Filed one", amount: -50) }

      before do
        create(:budget_spend_link, bank_transaction: filed, spend: create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 2), amount: 50))
      end

      def row(description)
        css_select("main ul.list li").find { |li| li.text.include?(description) }
      end

      it "opens the filing form from an unfiled one, which says Unfiled, and comes back to the Account" do
        get account_path(account)

        expect(row("Unfiled one").text.squish).to eq("Sep 4, 2026 Unfiled one Unfiled -$20.00")
        assert_select "li a.list-row[href='#{new_bank_transaction_filing_path(unfiled, from: "account")}']", text: /Unfiled one/
      end

      it "says an ignored one is, and offers to un-ignore it, which isn't a link to file it" do
        get account_path(account)

        expect(row("Ignored one").text.squish).to eq("Sep 3, 2026 Ignored one Ignored Un-ignore -$30.00")
        expect(row("Ignored one").css("a")).to be_empty
        assert_select "form[action='#{bank_transaction_ignore_path(ignored)}'] input[name=_method][value=delete]"
        assert_select "form[action='#{bank_transaction_ignore_path(ignored)}'] input[name=from][value=account]"
        assert_select "form[action='#{bank_transaction_ignore_path(ignored)}'] button", text: "Un-ignore"
      end

      it "shows what a filed one was filed as, and offers to un-file it" do
        get account_path(account)

        expect(row("Filed one").text.squish).to eq("Sep 2, 2026 Filed one Filed Spend from Groceries Un-file -$50.00")
        assert_select "form[action='#{bank_transaction_filing_path(filed)}'] input[name=_method][value=delete]"
        assert_select "form[action='#{bank_transaction_filing_path(filed)}'][data-turbo-confirm] button", text: "Un-file"
        assert_select "form[data-turbo-confirm='Un-file this bank transaction? This deletes the records it was filed as.']"
      end

      it "links the record it was filed as to where it's edited" do
        get account_path(account)

        spend = filed.spend_links.sole.spend
        assert_select "main ul.list li a[href='#{edit_spend_path(spend, month: "2026-09")}']", text: "Spend from Groceries"
      end

      it "names each kind of record, with an envelope or without" do
        deposit = create(:budget_bank_transaction, account: account, description: "Paid", amount: 10, date: Date.new(2026, 9, 5))
        create(:budget_deposit_link, bank_transaction: deposit)
        refunded = create(:budget_bank_transaction, account: account, description: "Returned", amount: 12.25, date: Date.new(2026, 9, 6))
        create(:budget_refund_link, bank_transaction: refunded, refund: create(:budget_refund, envelope: groceries, amount: 12.25))

        get account_path(account)

        expect(row("Paid").text.squish).to include("Deposit")
        expect(row("Paid").text).not_to include("Deposit from")
        expect(row("Returned").text.squish).to include("Refund to Groceries")
      end

      it "shows its records with their amounts when there are several, and each links to where it's edited" do
        split = create(:budget_bank_transaction, account: account, description: "Costco", amount: -100, date: Date.new(2026, 9, 7))
        household = create(:budget_envelope, budget: budget, name: "Household")
        create(:budget_spend_link, bank_transaction: split, spend: create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 7), amount: 60))
        create(:budget_spend_link, bank_transaction: split, spend: create(:budget_spend, envelope: household, date: Date.new(2026, 9, 7), amount: 40))

        get account_path(account)

        expect(row("Costco").text.squish).to include("Spend from Groceries, $60.00", "Spend from Household, $40.00")
        expect(row("Costco").text).not_to include("Doesn't add up")
      end

      describe "the flag" do
        it "says in words and colour when the records no longer add up, and isn't there when they do" do
          get account_path(account)
          expect(row("Filed one").text).not_to include("Doesn't add up")

          filed.spend_links.sole.spend.update!(amount: 40)
          get account_path(account)

          expect(row("Filed one").text.squish).to include("Doesn't add up", "Its records add up to $40.00, not $50.00.")
          assert_select "main ul.list li span.badge.badge-warning", text: "Doesn't add up"
        end

        it "blocks nothing: the bank transaction can still be un-filed, and the record is still ordinary" do
          filed.spend_links.sole.spend.update!(amount: 40)

          delete bank_transaction_filing_path(filed), params: { from: "account" }

          expect(filed.reload).to be_unfiled
        end

        it "isn't on one that's unfiled or ignored" do
          get account_path(account)

          expect(row("Unfiled one").text).not_to include("Doesn't add up")
          expect(row("Ignored one").text).not_to include("Doesn't add up")
        end
      end

      it "runs the same number of queries whatever the number of bank transactions or records, the flag included" do
        get account_path(account)
        few = count_queries { get account_path(account) }

        import = create(:budget_import, account: account)
        10.times do |n|
          bank_transaction = create(:budget_bank_transaction, account: account, import: import, description: "Merchant #{n}", amount: -10)
          create(:budget_spend_link, bank_transaction: bank_transaction, spend: create(:budget_spend, envelope: groceries, amount: 10 + n)) # Some of them don't add up.
        end
        create_list(:budget_bank_transaction, 10, :ignored, account: account, import: import)
        create_list(:budget_bank_transaction, 10, account: account, import: import)
        many = count_queries { get account_path(account) }

        expect(many).to eq(few)
      end
    end

    it "doesn't list another Account's bank transactions, even in the same budget" do
      other = create(:budget_account, budget: budget, name: "Visa")
      create(:budget_bank_transaction, account: other, description: "On the other card")
      create(:budget_bank_transaction, account: account, description: "On this one")

      get account_path(account)

      expect(response.body).to include("On this one")
      expect(response.body).not_to include("On the other card")
    end

    it "says when it has none, with a way to import some" do
      get account_path(account)

      assert_select "main", text: /No bank transactions yet/
      assert_select "main .border-dashed a.btn[href='#{new_account_import_path(account)}']", text: "Import"
    end

    it "links to the summary of its latest Import, which isn't its only Import" do
      create(:budget_import, account: account, file_name: "older.csv", created_at: 3.days.ago)
      latest = create(:budget_import, account: account, file_name: "newest.csv", created_at: 1.hour.ago)

      get account_path(account)

      assert_select "main a[href='#{import_path(latest)}']", text: /newest\.csv/
      expect(response.body).not_to include("older.csv")
    end

    describe "Undo of the latest Import" do
      it "is offered beside it, with a confirmation listing what it deletes, within 24 hours" do
        import = create(:budget_import, account: account, file_name: "newest.csv", created_at: 1.hour.ago)
        create_list(:budget_bank_transaction, 2, account: account, import: import)

        get account_path(account)

        assert_select "main form[action='#{import_path(import)}'][data-turbo-confirm='Undo the Import of newest.csv? This deletes its 2 bank transactions.']" do
          assert_select "input[name=_method][value=delete]"
          assert_select "button", text: "Undo"
        end
      end

      it "isn't offered after 24 hours" do
        create(:budget_import, account: account, file_name: "old.csv", created_at: 25.hours.ago)

        get account_path(account)

        assert_select "main button", text: "Undo", count: 0
        assert_select "main a", text: "old.csv"
      end

      it "is offered only for the latest, which is the only one the page shows" do
        create(:budget_import, account: account, file_name: "older.csv", created_at: 3.hours.ago)
        create(:budget_import, account: account, file_name: "newest.csv", created_at: 1.hour.ago)

        get account_path(account)

        assert_select "main form[data-turbo-confirm]", count: 1
      end
    end

    it "has no latest Import to link to until there is one" do
      get account_path(account)

      expect(css_select("main a").map { |link| link["href"] }).not_to include(a_string_matching(%r{\A/imports/}))
    end

    describe "with more bank transactions than a page" do
      before do
        import = create(:budget_import, account: account)
        # 120 of them, one a day, numbered by how recent they are, so the newest is "Merchant 1".
        120.times { |n| create(:budget_bank_transaction, account: account, import: import, description: "Merchant #{n + 1}", date: Date.new(2026, 9, 30) - n) }
      end

      def descriptions
        css_select("main ul.list li").map { |row| row.text[/Merchant \d+/] }
      end

      it "shows the first 50, with a link to the next, which are older" do
        get account_path(account)

        expect(descriptions).to eq((1..50).map { |n| "Merchant #{n}" })
        assert_select "nav[aria-label=Pages] a[rel=next][href='#{account_path(account, page: 2)}']", text: "Older"
        assert_select "nav[aria-label=Pages] a[rel=prev]", count: 0
      end

      it "shows the next 50 on page 2, with links both ways" do
        get account_path(account, page: 2)

        expect(descriptions).to eq((51..100).map { |n| "Merchant #{n}" })
        assert_select "nav[aria-label=Pages] a[rel=next][href='#{account_path(account, page: 3)}']", text: "Older"
        assert_select "nav[aria-label=Pages] a[rel=prev][href='#{account_path(account)}']", text: "Newer"
      end

      it "shows the rest on the last page, with only a way back" do
        get account_path(account, page: 3)

        expect(descriptions).to eq((101..120).map { |n| "Merchant #{n}" })
        assert_select "nav[aria-label=Pages] a[rel=next]", count: 0
        assert_select "nav[aria-label=Pages] a[rel=prev]", text: "Newer"
      end

      it "shows the first page for a page that isn't one, and nothing past the last" do
        [ "0", "-3", "abc", "" ].each do |page|
          get account_path(account, page: page)

          expect(descriptions.first).to eq("Merchant 1")
        end

        get account_path(account, page: 99_999_999_999_999_999)

        expect(response).to have_http_status(:ok)
        expect(descriptions).to be_empty
      end

      it "has no links to other pages when there's only one" do
        other = create(:budget_account, budget: budget, name: "Visa")
        create(:budget_bank_transaction, account: other)

        get account_path(other)

        assert_select "nav[aria-label=Pages]", count: 0
      end
    end

    it "runs the same number of queries whatever the number of bank transactions" do
      import = create(:budget_import, account: account)
      create(:budget_bank_transaction, account: account, import: import)
      get account_path(account)
      few = count_queries { get account_path(account) }

      40.times { create(:budget_bank_transaction, account: account, import: import) }
      many = count_queries { get account_path(account) }

      expect(many).to eq(few)
    end

    it "is not found for another user's Account" do
      get account_path(others_account)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /accounts/:id/edit" do
    let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }

    it "shows the form with its name, a Delete button and Cancel back to the Account" do
      get edit_account_path(account)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit account · Budgie"
      assert_select "h1", text: "Edit account"
      assert_select "form[action='#{account_path(account)}'] input[name=_method][value=patch]"
      assert_select "input[name='account[name]'][value=Chequing]"
      assert_select "form[data-turbo-confirm='Delete the Chequing account?'] input[name=_method][value=delete]"
      assert_select "a.btn[href='#{account_path(account)}']", text: "Cancel"
    end

    it "is not found for another user's Account" do
      get edit_account_path(others_account)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /accounts/:id" do
    let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }

    it "renames the Account, and goes back to its page" do
      patch account_path(account), params: { account: { name: "Joint chequing" } }

      expect(account.reload.name).to eq("Joint chequing")
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Account updated."
    end

    it "refuses what's wrong with it, and changes nothing" do
      patch account_path(account), params: { account: { name: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"
      expect(account.reload.name).to eq("Chequing")
    end

    it "never moves it to another budget" do
      other = create(:budget)

      patch account_path(account), params: { account: { name: "Moved", budget_id: other.id } }

      expect(account.reload).to have_attributes(name: "Moved", budget_id: budget.id)
    end

    it "is not found for another user's Account, which it doesn't change" do
      patch account_path(others_account), params: { account: { name: "Mine now" } }

      expect(response).to have_http_status(:not_found)
      expect(others_account.reload.name).to eq("Someone else's")
    end
  end

  describe "DELETE /accounts/:id" do
    let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }

    it "deletes the Account, and goes back to the list" do
      expect { delete account_path(account) }.to change(budget.accounts, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(accounts_path)
      follow_redirect!
      assert_select "[role=status]", text: "Account deleted."
    end

    it "deletes an Account that has Imports but no bank transactions, such as one of nothing but rows of 0, with them" do
      create(:budget_import, account: account, zero_rows_skipped: 4)

      expect { delete account_path(account) }.to change(Budget::Account, :count).by(-1).and change(Budget::Import, :count).by(-1)
    end

    it "refuses an Account with bank transactions, saying why on its page, and keeps it" do
      create(:budget_bank_transaction, account: account)

      expect { delete account_path(account) }.not_to change(Budget::Account, :count)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=alert]", text: "This account can't be deleted because it has bank transactions."
      assert_select "h1", text: "Chequing"
    end

    it "is not found for another user's Account, which it doesn't delete" do
      others_account

      expect { delete account_path(others_account) }.not_to change(Budget::Account, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
