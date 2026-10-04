require "rails_helper"

# The header's links to the pages that aren't a month's.
RSpec.describe "Navigation", type: :request do
  let(:budget) { create(:budget) }

  it "offers a signed-in person with a budget a link to each section, and says which they're on" do
    sign_in_as budget.user

    get csv_formats_path

    assert_select "header nav[aria-label=Sections] a", count: 6
    assert_select "header nav[aria-label=Sections] a[href='#{root_path}']:not([aria-current])", text: "Budget"
    assert_select "header nav[aria-label=Sections] a[href='#{records_path}']:not([aria-current])", text: "Records"
    assert_select "header nav[aria-label=Sections] a[href='#{accounts_path}']:not([aria-current])", text: "Accounts"
    assert_select "header nav[aria-label=Sections] a[href='#{bank_transactions_path}']:not([aria-current])", text: "Bank transactions"
    assert_select "header nav[aria-label=Sections] a[href='#{filing_rules_path}']:not([aria-current])", text: "Filing rules"
    assert_select "header nav[aria-label=Sections] a[href='#{csv_formats_path}'][aria-current=page]", text: "CSV formats"
  end

  it "says Budget is the one they're on in a month, and on its pages" do
    sign_in_as budget.user

    [ root_path, month_path("2026-09"), month_deposits_path("2026-09") ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{root_path}'][aria-current=page]", text: "Budget"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  it "says Records is the one they're on in the Records list" do
    sign_in_as budget.user

    get records_path

    assert_select "nav[aria-label=Sections] a[href='#{records_path}'][aria-current=page]", text: "Records"
    assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
  end

  it "says Bank transactions is the one they're on in the list, in any state, and in the review of what's guessed" do
    sign_in_as budget.user

    [ bank_transactions_path, bank_transactions_path(filter: { state: "unfiled" }), new_guessed_filing_path ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{bank_transactions_path}'][aria-current=page]", text: "Bank transactions"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  it "has no link to the Unfiled list any more, which is a state of the Bank transactions page" do
    sign_in_as budget.user

    get root_path

    assert_select "nav[aria-label=Sections] a", text: "Unfiled", count: 0
  end

  it "says Filing rules is the one they're on in the list, and while making or changing one" do
    sign_in_as budget.user
    rule = create(:budget_filing_rule, budget: budget)

    [ filing_rules_path, new_filing_rule_path, edit_filing_rule_path(rule) ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{filing_rules_path}'][aria-current=page]", text: "Filing rules"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  it "says CSV formats is the one they're on while building or changing one" do
    sign_in_as budget.user
    format = create(:budget_csv_format, budget: budget)

    [ new_csv_format_path, edit_csv_format_path(format) ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{csv_formats_path}'][aria-current=page]", text: "CSV formats"
    end
  end

  it "says Accounts is the one they're on at an Account, its Import's form, and an Import's summary" do
    sign_in_as budget.user
    account = create(:budget_account, budget: budget)
    import = create(:budget_import, account: account)

    [ accounts_path, new_account_path, account_path(account), edit_account_path(account), new_account_import_path(account), import_path(import) ].each do |path|
      get path

      assert_select "nav[aria-label=Sections] a[href='#{accounts_path}'][aria-current=page]", text: "Accounts"
      assert_select "nav[aria-label=Sections] a[aria-current=page]", count: 1
    end
  end

  it "doesn't change the main navigation, which is only signing out" do
    sign_in_as budget.user

    get root_path

    assert_select "nav[aria-label=Main] a", count: 0
    assert_select "nav[aria-label=Main] button", text: "Sign out"
  end

  it "is left out until there's a budget to go to" do
    sign_in_as create(:user)

    get new_budget_path

    assert_select "nav[aria-label=Sections]", count: 0
  end

  it "is left out when signed out" do
    get sign_in_path

    assert_select "nav[aria-label=Sections]", count: 0
  end
end
