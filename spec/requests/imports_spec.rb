require "rails_helper"

RSpec.describe "Imports", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:account) { create(:budget_account, budget: budget, name: "Chequing") }
  # The sample file's layout: a header row to skip, then the date, the description and one signed amount.
  let!(:csv_format) { create(:budget_csv_format, budget: budget, name: "Sample bank", rows_to_skip: 1) }
  let(:others_account) { create(:budget_account, name: "Someone else's") }
  let(:others_format) { create(:budget_csv_format, name: "Someone else's format") }

  before { sign_in_as budget.user }

  def upload(name = "signed-sample.csv")
    Rack::Test::UploadedFile.new(file_fixture(name), "text/csv")
  end

  def upload_text(text, name: "text.csv")
    Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: name)
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # What the CSV format select offers, as one line of text per option.
  def choices
    css_select("select[name='import[csv_format_id]'] option").map { |option| option.text.strip }
  end

  describe "GET /imports/new, the whole form" do
    it "shows a form for a file, a CSV format and an Account, all three required, which is what the header's Import leads to" do
      get new_import_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Import · Budgie"
      assert_select "h1", text: "Import"
      assert_select "form[action='#{imports_path}'][method=post][enctype='multipart/form-data']" do
        assert_select "label", text: "File"
        assert_select "input[type=file][name='import[file]'][required][accept='.csv,text/csv']"
        assert_select "label", text: "CSV format"
        assert_select "select[name='import[csv_format_id]'][required]"
        assert_select "label", text: "Account"
        assert_select "select[name='import[account_id]'][required]"
        assert_select "input[type=submit][value=Import]"
      end
      assert_select "option[selected]", count: 0
      assert_select "[data-import-file-target=again]", count: 0
    end

    it "offers the budget's CSV formats and Accounts alphabetically, after a prompt to choose each, and no one else's" do
      create(:budget_csv_format, budget: budget, name: "amex")
      create(:budget_account, budget: budget, name: "Visa")
      others_format
      others_account

      get new_import_path

      expect(choices).to eq([ "Choose a CSV format", "amex", "Sample bank" ])
      expect(css_select("select[name='import[account_id]'] option").map { |option| option.text.strip }).to eq([ "Choose an account", "Chequing", "Visa" ])
      expect(response.body).not_to include("Someone else")
    end

    it "says to build a CSV format first when there are none, instead of a form, with the existing words" do
      Budget::CsvFormat.where(budget: budget).delete_all

      get new_import_path

      expect(response).to have_http_status(:ok)
      assert_select "form[action='#{imports_path}']", count: 0
      assert_select "main", text: /You need a CSV format to read a file with\./
      assert_select "main a.btn[href='#{new_csv_format_path}']", text: "New CSV format"
    end

    it "says to make an Account when there are CSV formats and no Account" do
      Budget::Account.where(budget: budget).delete_all

      get new_import_path

      expect(response).to have_http_status(:ok)
      assert_select "form[action='#{imports_path}']", count: 0
      assert_select "main", text: /You need an Account to import into\./
      assert_select "main a.btn[href='#{new_account_path}']", text: "New account"
    end

    it "says the CSV format first when there is neither" do
      Budget::Account.where(budget: budget).delete_all
      Budget::CsvFormat.where(budget: budget).delete_all

      get new_import_path

      assert_select "main", text: /You need a CSV format to read a file with\./
      assert_select "main", text: /You need an Account/, count: 0
    end

    it "has no id twice, so the File label finds the form's own field and not the header's hidden one" do
      [ new_import_path, new_account_import_path(account) ].each do |path|
        get path

        ids = css_select("[id]").map { |element| element["id"] }
        expect(ids.tally.select { |_, count| count > 1 }).to eq({})
        expect(css_select("label[for=import_file]").size).to eq(1)
        expect(css_select("#import_file").map(&:name)).to eq([ "input" ])
        assert_select "main #import_file[type=file]"
        assert_select "header input[type=file]#header_import_file"
      end
    end

    it "is under Accounts in the header, and Cancel goes home" do
      get new_import_path

      assert_select "nav[aria-label=Sections] a[href='#{accounts_path}'][aria-current=page]", text: "Accounts"
      assert_select "a.btn[href='#{root_path}']", text: "Cancel"
    end

    it "requires sign-in" do
      delete session_path

      get new_import_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /imports, the whole form" do
    def import(file: upload, csv_format_id: csv_format.id, account_id: account.id)
      post imports_path, params: { import: { csv_format_id: csv_format_id, account_id: account_id, file: file }.compact }
    end

    it "reads the file into the Account that was chosen, with the CSV format that was, and goes to the summary" do
      expect { import }.to change(account.imports, :count).by(1).and change(account.bank_transactions, :count).by(5)

      created = account.imports.sole
      expect(created).to have_attributes(csv_format: csv_format, file_name: "signed-sample.csv", zero_rows_skipped: 1)
      expect(response).to redirect_to(import_path(created))
    end

    it "sets the Account's default CSV format, as any first Import does" do
      import

      expect(account.reload.default_csv_format).to eq(csv_format)
    end

    it "refuses an Account that isn't the budget's as one that can't be blank, and imports nothing" do
      expect { import(account_id: others_account.id) }.not_to change(Budget::Import, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Account can't be blank"
      assert_select "select[name='import[account_id]'][aria-invalid=true]"
      assert_select "p#import_account_id_error", text: "Account can't be blank"
    end

    it "refuses no Account, or one that isn't an id, the same way" do
      [ nil, "", "abc", "0", "99999999999999999999" ].each do |value|
        expect { import(account_id: value) }.not_to change(Budget::Import, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "Account can't be blank"
      end
    end

    it "refuses another budget's CSV format as one that can't be blank, as the Account's form does, and keeps the Account chosen" do
      expect { import(csv_format_id: others_format.id) }.not_to change(Budget::Import, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "CSV format can't be blank"
      assert_select "select[name='import[account_id]'] option[selected][value='#{account.id}']"
      assert_select "form[action='#{imports_path}']"
    end

    it "refuses a file that can't be read, naming the first row, and keeps the CSV format and the Account chosen" do
      expect { import(file: upload_text("Date,Description\n2026-09-01,Paycheck\n")) }.not_to change(Budget::Import, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Line 2: has 2 columns, and this CSV format expects 3."
      assert_select "select[name='import[csv_format_id]'] option[selected]", count: 1
      assert_select "select[name='import[account_id]'] option[selected]", count: 1
    end

    it "refuses no file" do
      post imports_path, params: { import: { csv_format_id: csv_format.id, account_id: account.id } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Choose a file to import."
    end

    it "is a bad request without an import" do
      post imports_path

      expect(response).to have_http_status(:bad_request)
    end

    it "requires sign-in" do
      delete session_path

      import

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "the Account's own form and the whole form, side by side" do
    it "keep the Account's form as it was: nested under the Account, with no Account to choose" do
      get new_account_import_path(account)

      assert_select "form[action='#{account_imports_path(account)}']"
      assert_select "select[name='import[account_id]']", count: 0
      assert_select "h1", text: "Import"
      assert_select "p", text: "Into Chequing"
    end

    it "takes the Account from the page for the Account's own form, whatever the params say" do
      post account_imports_path(account), params: { import: { csv_format_id: csv_format.id, account_id: others_account.id, file: upload } }

      expect(account.imports.count).to eq(1)
      expect(others_account.imports.count).to eq(0)
    end
  end

  describe "GET /accounts/:account_id/imports/new" do
    it "shows a form for a file and a CSV format" do
      get new_account_import_path(account)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Import into Chequing · Budgie"
      assert_select "h1", text: "Import"
      assert_select "form[action='#{account_imports_path(account)}'][method=post][enctype='multipart/form-data']" do
        assert_select "label", text: "File"
        assert_select "input[type=file][name='import[file]'][required][accept='.csv,text/csv']"
        assert_select "label", text: "CSV format"
        assert_select "select[name='import[csv_format_id]'][required]"
        assert_select "input[type=submit][value=Import]"
      end
      assert_select "a.btn[href='#{account_path(account)}']", text: "Cancel"
    end

    it "offers the budget's CSV formats alphabetically, after a prompt to choose one, and no one else's" do
      create(:budget_csv_format, budget: budget, name: "amex")
      others_format

      get new_account_import_path(account)

      expect(choices).to eq([ "Choose a CSV format", "amex", "Sample bank" ])
      expect(response.body).not_to include("Someone else")
    end

    it "starts with no CSV format chosen for an Account that hasn't had an Import" do
      get new_account_import_path(account)

      assert_select "option[selected]", count: 0
    end

    it "starts with the CSV format of the Account's most recent Import chosen" do
      amex = create(:budget_csv_format, budget: budget, name: "Amex")
      create(:budget_import, account: account, csv_format: csv_format, created_at: 3.days.ago)
      create(:budget_import, account: account, csv_format: amex, created_at: 1.hour.ago)
      create(:budget_import, account: account, csv_format: csv_format, created_at: 2.days.ago)
      create(:budget_import, account: create(:budget_account, budget: budget, name: "Other"), csv_format: csv_format)

      get new_account_import_path(account)

      assert_select "option[selected][value='#{amex.id}']", text: "Amex"
      assert_select "option[selected]", count: 1
    end

    it "starts with the Account's default CSV format chosen before its first Import" do
      amex = create(:budget_csv_format, budget: budget, name: "Amex")
      account.update!(default_csv_format: amex)

      get new_account_import_path(account)

      assert_select "option[selected][value='#{amex.id}']", text: "Amex"
      assert_select "option[selected]", count: 1
    end

    it "starts with the CSV format of the latest Import when there are Imports, whatever the default is" do
      amex = create(:budget_csv_format, budget: budget, name: "Amex")
      account.update!(default_csv_format: amex)
      create(:budget_import, account: account, csv_format: csv_format, created_at: 1.hour.ago)

      get new_account_import_path(account)

      assert_select "option[selected][value='#{csv_format.id}']", text: "Sample bank"
      assert_select "option[selected]", count: 1
    end

    it "starts with nothing chosen for an Account with no Import and no default" do
      get new_account_import_path(account)

      assert_select "option[selected]", count: 0
    end

    it "makes the format of a first Import the Account's default, so the next form starts on it" do
      expect(account.default_csv_format).to be_nil

      post account_imports_path(account), params: { import: { csv_format_id: csv_format.id, file: upload } }
      expect(account.reload.default_csv_format).to eq(csv_format)

      account.latest_import.undo
      get new_account_import_path(account)
      assert_select "option[selected][value='#{csv_format.id}']"
    end

    it "leaves the default alone when the Account has one and the Import used another format" do
      amex = create(:budget_csv_format, budget: budget, name: "Amex")
      account.update!(default_csv_format: amex)

      post account_imports_path(account), params: { import: { csv_format_id: csv_format.id, file: upload } }

      expect(account.reload.default_csv_format).to eq(amex)
    end

    it "sets no default from a refused Import" do
      post account_imports_path(account), params: { import: { csv_format_id: csv_format.id, file: upload_text("nonsense") } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload.default_csv_format).to be_nil
    end

    it "says to build a CSV format first when there are none, instead of a form" do
      Budget::CsvFormat.where(budget: budget).delete_all

      get new_account_import_path(account)

      expect(response).to have_http_status(:ok)
      assert_select "form[action='#{account_imports_path(account)}']", count: 0
      assert_select "main", text: /You need a CSV format to read a file with/
      assert_select "main a.btn[href='#{new_csv_format_path}']", text: "New CSV format"
    end

    it "is not found for another user's Account" do
      get new_account_import_path(others_account)

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get new_account_import_path(account)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /accounts/:account_id/imports" do
    def import(file: upload, csv_format_id: csv_format.id, account: self.account)
      params = { import: { csv_format_id: csv_format_id, file: file }.compact }
      post account_imports_path(account), params: params
    end

    it "reads the file into the Account, and goes to the Import's summary" do
      expect { import }.to change(account.imports, :count).by(1).and change(account.bank_transactions, :count).by(5)

      created = account.imports.sole
      expect(created).to have_attributes(csv_format: csv_format, file_name: "signed-sample.csv", duplicates_skipped: 0, zero_rows_skipped: 1)
      expect(account.bank_transactions.newest_first.pluck(:description, :amount)).to eq([
        [ "Hydro rebate", BigDecimal("12.25") ], [ "Coffee shop", BigDecimal("-4.25") ], [ "Hydro", BigDecimal("-65.5") ],
        [ "Loblaws", BigDecimal("-82.45") ], [ "Paycheck", 2800 ]
      ])
      expect(response).to redirect_to(import_path(created))
    end

    it "imports a row the bank gave no description as No description, which an Account's page lists like any other" do
      import(file: upload_text("Date,Description,Amount\n2026-09-02,,-250.00\n2026-09-03,Loblaws,-82.45\n"))

      expect(response).to redirect_to(import_path(account.imports.sole))
      expect(account.bank_transactions.newest_first.pluck(:description, :amount)).to eq([ [ "Loblaws", BigDecimal("-82.45") ], [ "No description", -250 ] ])

      get account_path(account)

      expect(visible_text).to include("No description", "-$250.00")
    end

    it "keeps only the name of the file, which isn't kept" do
      import

      expect(Budget::Import.column_names).not_to include("file", "contents", "content", "body")
    end

    it "adds only what's new when the same file is imported again, and says it skipped the rest" do
      import
      import
      follow_redirect!

      expect(account.bank_transactions.count).to eq(5)
      expect(account.imports.count).to eq(2)
      expect(account.imports.latest_first.first).to have_attributes(duplicates_skipped: 5)
    end

    describe "a file that's refused" do
      it "creates nothing, names the first bad row by its line and why, and keeps the CSV format chosen" do
        file = upload_text("Date,Description,Amount\n2026-09-01,Paycheck,2800.00\n2026-13-45,Loblaws,-82.45\n2026-09-03,Hydro,abc\n")

        expect { import(file: file) }.to not_change(Budget::Import, :count).and not_change(Budget::BankTransaction, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "Line 3: the date \"2026-13-45\" isn't a date in year, month, day order."
        assert_select "option[selected][value='#{csv_format.id}']", text: "Sample bank"
        assert_select "h1", text: "Import"
      end

      it "says so for a file that isn't UTF-8" do
        import file: upload_text("Date,Description,Amount\n2026-09-01,Caf\xE9,-5.00\n".b)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again."
      end

      it "is refused without a file" do
        expect { import(file: nil) }.not_to change(Budget::Import, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "Choose a file to import."
      end

      it "doesn't take something that isn't a file for one" do
        expect { import(file: "2026-09-01,Paycheck,2800.00") }.not_to change(Budget::Import, :count)

        assert_select "[role=alert] li", text: "Choose a file to import."
      end

      it "is refused without a CSV format" do
        expect { import(csv_format_id: nil) }.not_to change(Budget::Import, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "CSV format can't be blank"
      end

      it "is refused with another budget's CSV format, as with none, and reads nothing with it" do
        expect { import(csv_format_id: others_format.id) }.not_to change(Budget::BankTransaction, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "CSV format can't be blank"
        assert_select "option[selected]", count: 0
        expect(response.body).not_to include("Someone else")
      end

      it "doesn't take a CSV format that isn't an id" do
        [ "not-an-id", "0", "" ].each do |id|
          import(csv_format_id: id)

          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end

    it "is not found for another user's Account, and imports nothing into it" do
      expect { import(account: others_account) }.not_to change(Budget::BankTransaction, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "is a bad request without an import" do
      post account_imports_path(account)

      expect(response).to have_http_status(:bad_request)
    end

    it "requires sign-in" do
      delete session_path

      import

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "GET /imports/:id, its summary" do
    let(:import) { account.imports.build(csv_format: csv_format, file_name: "september.csv").tap { |import| import.run(File.read(file_fixture("signed-sample.csv"))) } }

    before { travel_to Time.utc(2026, 10, 15, 16) }

    it "says what was imported: the dates, the money in and the money out, and what was skipped" do
      get import_path(import)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Import of september.csv · Budgie"
      assert_select "h1", text: "Import"
      expect(visible_text).to include("september.csv", "Chequing")
      expect(visible_text).to include("Added 5 bank transactions")
      expect(visible_text).to include("Dates Sep 1, 2026 to Sep 9, 2026 In the file")
      expect(visible_text).to include("Money in $2,812.25 2 bank transactions in the file")
      expect(visible_text).to include("Money out -$152.20 3 bank transactions in the file")
      expect(visible_text).to include("Duplicates skipped 0")
      expect(visible_text).to include("Rows of 0 skipped 1")
    end

    it "says which Account and CSV format it used, for every Import, so a wrong guess from the header is seen at once" do
      get import_path(import)

      expect(visible_text).to include("Into Chequing, read with the Sample bank CSV format.")
      assert_select "main p.font-medium", text: "Into Chequing, read with the Sample bank CSV format."
    end

    it "says it for an Import of the same file again too, which added nothing" do
      import
      again = account.imports.build(csv_format: csv_format, file_name: "again.csv").tap { |second| second.run(File.read(file_fixture("signed-sample.csv"))) }

      get import_path(again)

      expect(visible_text).to include("Nothing new was added.", "Into Chequing, read with the Sample bank CSV format.")
    end

    it "says how many bank transactions Filing rules filed and ignored, which is none when there are no rules" do
      get import_path(import)

      expect(visible_text).to include("Filed by Filing rules 0 bank transactions", "Ignored by Filing rules 0 bank transactions")
    end

    it "says how many Filing rules filed and ignored, as the Import did them, whatever has been done to them since" do
      groceries = create(:budget_envelope, budget: budget, name: "Groceries")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "hydro")
      create(:budget_filing_rule, :ignore, budget: budget, text: "coffee shop")

      get import_path(import)

      expect(visible_text).to include("Filed by Filing rules 2 bank transactions", "Ignored by Filing rules 1 bank transaction")

      account.bank_transactions.find_by!(description: "Loblaws").unfile
      get import_path(import)

      expect(visible_text).to include("Filed by Filing rules 2 bank transactions")
    end

    it "shows the first row as it was read, with its date spelled out and which way the money went, so a wrong sign or a swapped day and month is seen" do
      get import_path(import)

      assert_select "main h2", text: "First row"
      expect(css_select("main ul.list li").map { |row| row.text.squish }).to eq([ "Sep 1, 2026 Paycheck Money in $2,800.00" ])
    end

    it "says when the first row was money out" do
      out = account.imports.build(csv_format: csv_format, file_name: "out.csv").tap { |i| i.run("Date,Description,Amount\n2026-09-02,Loblaws,-82.45\n") }

      get import_path(out)

      expect(css_select("main ul.list li").map { |row| row.text.squish }).to eq([ "Sep 2, 2026 Loblaws Money out -$82.45" ])
    end

    it "says how many were duplicates, when a file overlaps what's there, and still says what the whole file held" do
      import
      overlap = account.imports.build(csv_format: csv_format, file_name: "october.csv").tap do |i|
        i.run("Date,Description,Amount\n2026-09-09,Hydro rebate,12.25\n2026-09-20,Gym,-30.00\n")
      end

      get import_path(overlap)

      expect(visible_text).to include("Added 1 bank transaction")
      expect(visible_text).to include("Duplicates skipped 1")
      expect(visible_text).to include("Dates Sep 9, 2026 to Sep 20, 2026 In the file")
      expect(visible_text).to include("Money in $12.25 1 bank transaction in the file", "Money out -$30.00 1 bank transaction in the file")
    end

    it "shows the file's first row, even when it was already in the account, which is the row a wrong sign would show on" do
      import
      overlap = account.imports.build(csv_format: csv_format, file_name: "october.csv").tap do |i|
        i.run("Date,Description,Amount\n2026-09-09,Hydro rebate,12.25\n2026-09-20,Gym,-30.00\n")
      end

      get import_path(overlap)

      expect(css_select("main ul.list li").map { |row| row.text.squish }).to eq([ "Sep 9, 2026 Hydro rebate Money in $12.25" ])
    end

    it "says nothing new was added, when it added nothing, but still what the file held and what it skipped" do
      import
      again = account.imports.build(csv_format: csv_format, file_name: "again.csv").tap { |i| i.run(File.read(file_fixture("signed-sample.csv"))) }

      get import_path(again)

      expect(visible_text).to include("Nothing new was added. Every row in the file was already in this account.")
      expect(visible_text).to include("Added 0 bank transactions", "Duplicates skipped 5", "Rows of 0 skipped 1")
      expect(visible_text).to include("Dates Sep 1, 2026 to Sep 9, 2026 In the file", "Money in $2,812.25", "Money out -$152.20")
      assert_select "main h2", text: "First row"
      expect(css_select("main ul.list li").map { |row| row.text.squish }).to eq([ "Sep 1, 2026 Paycheck Money in $2,800.00" ])
    end

    it "says nothing new was added for a file of nothing but rows of 0, with no dates, money or first row" do
      zeros = account.imports.build(csv_format: csv_format, file_name: "zeros.csv").tap { |i| i.run("Date,Description,Amount\n2026-09-02,Interest,0.00\n") }

      get import_path(zeros)

      expect(visible_text).to include("Nothing new was added. Every row in the file was a row of 0.", "Rows of 0 skipped 1")
      expect(visible_text).not_to include("Dates", "Money in", "Money out")
      assert_select "main h2", text: "First row", count: 0
    end

    describe "Undo" do
      it "is offered, with a confirmation that lists what it deletes, while it's the Account's latest Import and within 24 hours" do
        get import_path(import)

        assert_select "main form[action='#{import_path(import)}'][data-turbo-confirm='Undo the Import of september.csv? This deletes its 5 bank transactions.']" do
          assert_select "input[name=_method][value=delete]"
          assert_select "button.btn", text: "Undo"
        end
        expect(visible_text).to include("You can undo this Import until Oct 16, 2026 at 12:00 PM, while it's the latest in this account.")
      end

      it "counts the records its bank transactions were filed as too, by kind" do
        groceries = create(:budget_envelope, budget: budget, name: "Groceries")
        import.bank_transactions.where(description: %w[ Loblaws Hydro ]).each do |bank_transaction|
          create(:budget_spend_link, bank_transaction: bank_transaction, spend: create(:budget_spend, envelope: groceries, amount: bank_transaction.amount.abs))
        end
        create(:budget_deposit_link, bank_transaction: import.bank_transactions.find_by!(description: "Paycheck"), deposit: create(:budget_deposit, budget: budget, amount: 2800))

        get import_path(import)

        assert_select "form[data-turbo-confirm='Undo the Import of september.csv? This deletes its 5 bank transactions and the 1 Deposit and 2 Spends filed from them.']"
      end

      it "counts one bank transaction in the singular, and says when there are none" do
        one = account.imports.build(csv_format: csv_format, file_name: "one.csv").tap { |i| i.run("Date,Description,Amount\n2026-09-03,Hydro,-65.50\n") }
        get import_path(one)
        assert_select "form[data-turbo-confirm='Undo the Import of one.csv? This deletes its 1 bank transaction.']"

        none = account.imports.build(csv_format: csv_format, file_name: "none.csv").tap { |i| i.run("Date,Description,Amount\n2026-09-02,Interest,0.00\n") }
        get import_path(none)
        assert_select "form[data-turbo-confirm='Undo the Import of none.csv? It added no bank transactions, so this only takes the Import away.']"
      end

      it "isn't offered once 24 hours are up, and says why" do
        import

        travel_to Time.utc(2026, 10, 16, 16, 1) do
          get import_path(import)
        end

        assert_select "main form[data-turbo-confirm]", count: 0
        assert_select "main button", text: "Undo", count: 0
        expect(visible_text).to include("This Import ran more than 24 hours ago, so it can't be undone.")
      end

      it "isn't offered for an Import that isn't the Account's latest, and says why" do
        import
        travel_to(1.hour.from_now) { account.imports.build(csv_format: csv_format, file_name: "newer.csv").run("Date,Description,Amount\n2026-09-30,Gym,-30.00\n") }

        get import_path(import)

        assert_select "main button", text: "Undo", count: 0
        expect(visible_text).to include("This Import can't be undone while a newer Import is in this account. Undo that one first.")
      end

      it "is offered for another Account's Import that is its latest, whatever this Account has" do
        other = create(:budget_account, budget: budget, name: "Visa")
        theirs = other.imports.build(csv_format: csv_format, file_name: "visa.csv").tap { |i| i.run("Date,Description,Amount\n2026-09-30,Gym,-30.00\n") }
        import

        get import_path(theirs)

        assert_select "main button", text: "Undo"
      end
    end

    it "links back to the Account" do
      get import_path(import)

      assert_select "main a[href='#{account_path(account)}']", text: "Back to Chequing"
    end

    it "runs the same number of queries whatever the number of bank transactions" do
      # In Accounts of their own, so each is its Account's latest Import, and offers Undo, which counts what it would delete.
      small = create(:budget_account, budget: budget, name: "Visa").imports.build(csv_format: csv_format, file_name: "small.csv")
        .tap { |i| i.run("Date,Description,Amount\n2026-09-01,Merchant 1,-1.00\n") }
      big_rows = (1..300).map { |n| "2026-09-#{format("%02d", (n % 28) + 1)},Merchant #{n},-#{n}.25\n" }.join
      big = account.imports.build(csv_format: csv_format, file_name: "big.csv").tap { |i| i.run("Date,Description,Amount\n#{big_rows}") }
      get import_path(small)

      queries_for_small = count_queries { get import_path(small) }
      queries_for_big = count_queries { get import_path(big) }

      expect(queries_for_big).to eq(queries_for_small)
    end

    it "is not found for another user's Import" do
      get import_path(create(:budget_import))

      expect(response).to have_http_status(:not_found)
    end

    it "requires sign-in" do
      delete session_path

      get import_path(import)

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "DELETE /imports/:id, undoing it" do
    before { travel_to Time.utc(2026, 10, 15, 16) }

    let!(:import) { account.imports.build(csv_format: csv_format, file_name: "september.csv").tap { |i| i.run(File.read(file_fixture("signed-sample.csv"))) } }

    it "deletes the Import and its bank transactions, and goes back to the Account with a notice" do
      expect { delete import_path(import) }.to change(account.imports, :count).by(-1).and change(account.bank_transactions, :count).by(-5)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(account_path(account))
      follow_redirect!
      assert_select "[role=status]", text: "Import undone."
      assert_select "main", text: /No bank transactions yet/
    end

    it "brings the file's rows back when it's imported again" do
      delete import_path(import)

      post account_imports_path(account), params: { import: { csv_format_id: csv_format.id, file: upload } }

      expect(account.bank_transactions.count).to eq(5)
      expect(account.imports.sole).to have_attributes(duplicates_skipped: 0)
    end

    it "is refused after 24 hours, with the alert on the Import's summary, and changes nothing" do
      travel_to(Time.utc(2026, 10, 16, 16, 1)) do
        expect { delete import_path(import) }.not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }
      end

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(import_path(import))
      follow_redirect!
      assert_select "[role=alert]", text: "This Import ran more than 24 hours ago, so it can't be undone."
      assert_select "h1", text: "Import"
    end

    it "is refused for an Import that has a newer Import after it, and changes nothing" do
      travel_to(1.hour.from_now) { account.imports.build(csv_format: csv_format, file_name: "newer.csv").run("Date,Description,Amount\n2026-09-30,Gym,-30.00\n") }

      expect { delete import_path(import) }.not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }

      expect(response).to redirect_to(import_path(import))
      follow_redirect!
      assert_select "[role=alert]", text: "This Import can't be undone while a newer Import is in this account. Undo that one first."
    end

    it "undoes the one before once the latest has been, in turn" do
      newer = nil
      travel_to(1.hour.from_now) { newer = account.imports.build(csv_format: csv_format, file_name: "newer.csv").tap { |i| i.run("Date,Description,Amount\n2026-09-30,Gym,-30.00\n") } }

      delete import_path(newer)
      delete import_path(import)

      expect(account.imports).to be_empty
      expect(account.bank_transactions).to be_empty
    end

    it "is not found for another user's Import, which it doesn't undo" do
      others = create(:budget_import)

      expect { delete import_path(others) }.not_to change(Budget::Import, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "leaves another Account's Imports and bank transactions alone" do
      other = create(:budget_account, budget: budget, name: "Visa")
      theirs = other.imports.build(csv_format: csv_format, file_name: "visa.csv").tap { |i| i.run("Date,Description,Amount\n2026-09-30,Gym,-30.00\n") }

      delete import_path(import)

      expect(Budget::Import.exists?(theirs.id)).to be(true)
      expect(other.bank_transactions.count).to eq(1)
    end

    it "requires sign-in" do
      delete session_path

      delete import_path(import)

      expect(response).to redirect_to(sign_in_path)
      expect(Budget::Import.exists?(import.id)).to be(true)
    end
  end
end
