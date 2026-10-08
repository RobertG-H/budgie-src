require "rails_helper"

# Import from the header: the file alone. It imports straight away only when the CSV format that reads it and the Account it's for are each
# certain, and otherwise shows the whole form with the best offer chosen, creating nothing (ADR 0014).
RSpec.describe "Importing from the header", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  # The sample file's layout: a header row to skip, then the date, the description and one signed amount.
  let!(:csv_format) { create(:budget_csv_format, budget: budget, name: "TD", rows_to_skip: 1) }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing", default_csv_format: csv_format) }

  before { sign_in_as budget.user }

  def upload(name = "signed-sample.csv")
    Rack::Test::UploadedFile.new(file_fixture(name), "text/csv")
  end

  def upload_text(text, name: "text.csv")
    Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: name)
  end

  def guess(file = upload)
    post import_guess_path, params: { import: { file: file } }
  end

  def visible_text
    Nokogiri::HTML(response.body).at("main").text.squish
  end

  # What a select offers, as one line of text per option, and which of them is chosen.
  def choices(name)
    css_select("select[name='import[#{name}]'] option").map { |option| option.text.strip }
  end

  def chosen(name)
    css_select("select[name='import[#{name}]'] option[selected]").map { |option| option.text.strip }
  end

  describe "when the CSV format and the Account are both certain" do
    it "imports the file into the Account with the CSV format, and lands on the Import's summary, with a notice that says what it did" do
      expect { guess }.to change(chequing.imports, :count).by(1).and change(chequing.bank_transactions, :count).by(5)

      import = chequing.imports.sole
      expect(import).to have_attributes(csv_format: csv_format, file_name: "signed-sample.csv", duplicates_skipped: 0, zero_rows_skipped: 1)
      expect(response).to redirect_to(import_path(import))
      follow_redirect!
      assert_select "[role=status]", text: "Imported signed-sample.csv into Chequing, read with the TD CSV format."
    end

    it "makes the same Import the Account's own form would, and files nothing else" do
      expect { guess }.not_to change { [ Budget::Deposit.count, Budget::Spend.count, Budget::Refund.count, Budget::FilingRule.count ] }

      expect(chequing.bank_transactions.newest_first.pluck(:description, :amount).first).to eq([ "Hydro rebate", BigDecimal("12.25") ])
      expect(chequing.bank_transactions.all?(&:unfiled?)).to be(true)
    end

    it "has the Filing rules act on the rows, as any Import does" do
      groceries = create(:budget_envelope, budget: budget, name: "Groceries")
      create(:budget_filing_rule, budget: budget, envelope: groceries, text: "loblaws")

      guess

      expect(chequing.imports.sole).to have_attributes(filed_by_rules: 1)
    end

    it "says on the summary which Account and CSV format it used, with Undo beside it" do
      guess
      follow_redirect!

      expect(visible_text).to include("Into Chequing, read with the TD CSV format.")
      assert_select "form[action='#{import_path(chequing.imports.sole)}'] button", text: "Undo"
    end

    it "keeps the Import when it's the same file again, which adds nothing, and says so on its summary" do
      guess
      expect { guess(upload) }.to change(chequing.imports, :count).by(1).and change(chequing.bank_transactions, :count).by(0)

      expect(chequing.latest_import).to have_attributes(duplicates_skipped: 5)
      follow_redirect!
      expect(visible_text).to include("Nothing new was added. Every row in the file was already in this account.")
      expect(visible_text).to include("Into Chequing, read with the TD CSV format.")
    end

    it "is certain of the format when two have identical columns, and imports with the one the Account has as its default" do
      create(:budget_csv_format, budget: budget, name: "Same columns", rows_to_skip: 1)

      expect { guess }.to change(chequing.imports, :count).by(1)

      expect(chequing.imports.sole.csv_format).to eq(csv_format)
    end

    it "leaves the Account's default as it was" do
      amex = create(:budget_csv_format, budget: budget, name: "Amex", column_count: 4)
      other = create(:budget_account, budget: budget, name: "Visa", default_csv_format: amex)

      guess

      expect(chequing.reload.default_csv_format).to eq(csv_format)
      expect(other.reload.default_csv_format).to eq(amex)
    end

    it "never uses another budget's CSV formats or Accounts" do
      theirs = create(:budget_csv_format, rows_to_skip: 1)
      create(:budget_account, budget: theirs.budget, default_csv_format: theirs)

      guess

      expect(chequing.imports.sole.csv_format).to eq(csv_format)
    end
  end

  describe "when the CSV format is certain and no Account has it as its default" do
    before { chequing.update!(default_csv_format: nil) }

    it "shows the whole form, with the format chosen and the Account to choose, and says what was guessed, creating nothing" do
      expect { guess }.not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "h1", text: "Import"
      assert_select "form[action='#{imports_path}'][method=post][enctype='multipart/form-data']" do
        assert_select "input[type=file][name='import[file]'][required]"
        assert_select "select[name='import[csv_format_id]'][required]"
        assert_select "select[name='import[account_id]'][required]"
      end
      expect(chosen("csv_format_id")).to eq([ "TD" ])
      expect(chosen("account_id")).to eq([])
      expect(choices("account_id")).to eq([ "Choose an account", "Chequing" ])
      assert_select "[role=status]", text: /None of your Accounts has the TD CSV format as its default, so choose the Account the file is for./
    end

    it "says to choose the file again, since it isn't kept, and carries the way for the browser to put it back" do
      guess

      assert_select "form[data-controller=import-file] [data-import-file-target=again]", text: /Choose the file again./
      assert_select "form[data-controller=import-file] input[type=file][data-import-file-target=input]"
    end

    it "has no error summary: nothing was refused, it only wasn't certain" do
      guess

      assert_select "main [role=alert]", count: 0
    end
  end

  describe "when several Accounts have the CSV format as their default" do
    let!(:visa) { create(:budget_account, budget: budget, name: "Visa", default_csv_format: csv_format) }
    let!(:savings) { create(:budget_account, budget: budget, name: "Savings", default_csv_format: csv_format) }

    before do
      create(:budget_import, account: chequing, csv_format: csv_format, created_at: 3.days.ago)
      create(:budget_import, account: visa, csv_format: csv_format, created_at: 1.hour.ago)
      create(:budget_import, account: savings, csv_format: csv_format, created_at: 2.days.ago)
    end

    it "offers the Account imported into most recently, but doesn't import: duplicates are judged per Account" do
      expect { guess }.not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(chosen("csv_format_id")).to eq([ "TD" ])
      expect(chosen("account_id")).to eq([ "Visa" ])
      expect(choices("account_id")).to eq([ "Chequing", "Savings", "Visa" ])
      assert_select "[role=status]", text: /More than one of your Accounts has the TD CSV format as its default, so check the Account the file is for./
    end
  end

  describe "when several CSV formats read the file differently" do
    let!(:inverted) { create(:budget_csv_format, budget: budget, name: "Inverted", rows_to_skip: 1, invert_sign: true) }

    it "offers the one the most recent Import used, says to check it, and imports nothing" do
      create(:budget_import, account: chequing, csv_format: inverted, created_at: 1.hour.ago)
      create(:budget_import, account: chequing, csv_format: csv_format, created_at: 2.days.ago)
      Budget::Import.delete_all

      expect { guess }.not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(chosen("csv_format_id")).not_to be_empty
      assert_select "[role=status]", text: /More than one of your CSV formats reads this file. Check the CSV format./
    end

    it "chooses the Account from the format it offers, which is the one whose default it is, if there is exactly one" do
      inverted.update!(created_at: 1.minute.from_now)
      visa = create(:budget_account, budget: budget, name: "Visa", default_csv_format: inverted)

      guess

      expect(chosen("csv_format_id")).to eq([ "Inverted" ])
      expect(chosen("account_id")).to eq([ visa.name ])
    end
  end

  describe "when no CSV format reads the file" do
    it "shows the whole form with no format chosen, says so, and lists each format's first refusal under Why, with a way to the builder" do
      amex = create(:budget_csv_format, budget: budget, name: "Amex", column_count: 4)

      expect { guess(upload_text("Date,Description\n2026-09-01,Paycheck\n", name: "odd.csv")) }.not_to change { [ Budget::Import.count, Budget::BankTransaction.count ] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(chosen("csv_format_id")).to eq([])
      assert_select "[role=alert] p", text: "No CSV format reads this file."
      assert_select "[role=alert] details summary", text: "Why"
      expect(css_select("[role=alert] details li").map { |item| item.text.squish }).to eq([
        "Amex: Line 1: has 2 columns, and this CSV format expects 4.",
        "TD: Line 2: has 2 columns, and this CSV format expects 3."
      ])
      assert_select "[role=alert] a.btn[href='#{new_csv_format_path}']", text: "New CSV format"
      expect(visible_text).to include("In the CSV format builder, choose the same file as its sample.")
      expect(amex).to be_present
    end

    it "names the date a format couldn't read, in the words the reader uses" do
      guess(upload_text("Date,Description,Amount\n04/09/2026,Paycheck,2800.00\n"))

      expect(visible_text).to include("TD: Line 2: the date \"04/09/2026\" isn't a date in year, month, day order.")
    end

    it "says what's wrong with the file once, and lists no formats, when it's every format's: it isn't UTF-8, it's empty, it isn't CSV" do
      create(:budget_csv_format, budget: budget, name: "Amex", column_count: 4)

      [ upload_text("Date,Description,Amount\n2026-09-01,Caf\xE9,-5.00\n".b), upload_text(""), upload_text("a,\"b\n") ].each do |file|
        guess(file)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] details", count: 0
        assert_select "[role=alert]", text: /Choose another file\./
        expect(chosen("csv_format_id")).to eq([])
      end
    end

    it "gives the exact message for the file, such as that it isn't UTF-8" do
      guess(upload_text("2026-09-01,Caf\xE9,-5.00\n".b))

      assert_select "[role=alert] span", text: "The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again. Choose another file."
    end
  end

  describe "when there's nothing to guess with" do
    it "goes to the whole form, which says what's missing, when the budget has no CSV format" do
      Budget::Account.update_all(default_csv_format_id: nil)
      Budget::CsvFormat.where(budget: budget).delete_all

      expect { guess }.not_to change(Budget::Import, :count)

      expect(response).to redirect_to(new_import_path)
    end

    it "goes to the whole form when the budget has no Account" do
      Budget::Account.where(budget: budget).delete_all

      expect { guess }.not_to change(Budget::Import, :count)

      expect(response).to redirect_to(new_import_path)
    end
  end

  describe "a request that isn't a file" do
    it "shows the whole form with 'Choose a file to import.' when what was sent as the file isn't one" do
      post import_guess_path, params: { import: { file: "not a file" } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Choose a file to import."
      expect(Budget::Import.count).to eq(0)
    end

    it "is a bad request without an import at all" do
      post import_guess_path

      expect(response).to have_http_status(:bad_request)
    end

    it "requires sign-in" do
      delete session_path

      guess

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "the number of queries" do
    it "doesn't grow with the rows of the file, however many formats there are" do
      create(:budget_csv_format, budget: budget, name: "Amex", column_count: 4)
      small = "Date,Description,Amount\n" + "2026-09-01,Tea,-1.00\n" * 5
      big = "Date,Description,Amount\n" + "2026-09-02,Coffee shop,-1.00\n" * 1000

      guess(upload_text("2026-09-03,Prime,-1.00\n", name: "prime.csv"))
      few = count_queries { guess(upload_text(small, name: "small.csv")) }
      many = count_queries { guess(upload_text(big, name: "big.csv")) }

      expect(many).to eq(few)
    end
  end
end
