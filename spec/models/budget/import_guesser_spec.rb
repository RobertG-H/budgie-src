require "rails_helper"

# Which CSV format reads a file, and which Account it's for, worked out from the budget's own CSV formats and Accounts, so that an Import from
# the header can run without a form when it's certain (ADR 0014). It reads the file once, with every CSV format, and never creates anything.
RSpec.describe Budget::ImportGuesser do
  let(:budget) { create(:budget) }
  # A date, a description and a signed amount, which the factory's CSV format reads.
  let(:file) { "2026-09-01,Paycheck,2800.00\n2026-09-02,Loblaws,-82.45\n" }

  def guess(text = file, budget: self.budget)
    Budget::ImportGuesser.new(budget).guess(text)
  end

  # A CSV format that reads `file`, as the factory's does, and one that reads it with the sign inverted, so the rows come out different.
  def format(name, **attributes)
    create(:budget_csv_format, { budget: budget, name: name }.merge(attributes))
  end

  def account(name, default: nil)
    create(:budget_account, budget: budget, name: name, default_csv_format: default)
  end

  describe "a complete guess" do
    it "is one CSV format that reads the file cleanly, and one Account that has it as its default" do
      td = format("TD CSV")
      chequing = account("Chequing", default: td)

      result = guess

      expect(result).to be_complete
      expect(result.csv_format).to eq(td)
      expect(result.account).to eq(chequing)
      expect(result).to be_format_certain
      expect(result).to be_account_certain
      expect(result.refusals).to eq([])
      expect(result.file_refusal).to be_nil
    end

    it "ignores the CSV formats that don't read the file, and the Accounts that have those as their default" do
      td = format("TD CSV")
      four_columns = format("Four columns", column_count: 4)
      chequing = account("Chequing", default: td)
      account("Visa", default: four_columns)

      result = guess

      expect(result).to be_complete
      expect([ result.csv_format, result.account ]).to eq([ td, chequing ])
      expect(result.refusals).to eq([])
      expect(four_columns).to be_present
    end

    it "is certain of the format when two have the same columns, since they read the same rows, and takes the one the most recent Import used" do
      older = format("Older", created_at: 3.days.ago)
      newer = format("Newer", created_at: 1.day.ago)
      create(:budget_import, account: account("Other"), csv_format: older, created_at: 1.hour.ago)
      create(:budget_import, account: account("Other two"), csv_format: newer, created_at: 2.days.ago)
      chequing = account("Chequing", default: older)

      result = guess

      expect(result.csv_format).to eq(older)
      expect(result).to be_format_certain
      expect(result.account).to eq(chequing)
      expect(result).to be_complete
    end

    it "takes the newest of identical formats when none of them has been used, and is still certain" do
      format("First", created_at: 3.days.ago)
      newest = format("Newest", created_at: 1.day.ago)
      format("Middle", created_at: 2.days.ago)
      chequing = account("Chequing", default: newest)

      result = guess

      expect(result.csv_format).to eq(newest)
      expect(result).to be_format_certain
      expect(result).to be_complete
      expect(result.account).to eq(chequing)
    end

    it "treats formats with identical columns as one when finding the Account, and reads with the Account's own, wherever the tie-break would have gone" do
      older = format("Older", created_at: 3.days.ago)
      format("Newer", created_at: 1.day.ago)
      chequing = account("Chequing", default: older)

      result = guess

      expect(result).to be_complete
      expect(result.account).to eq(chequing)
      expect(result.csv_format).to eq(older)
    end

    it "isn't certain of the Account when two Accounts have identical formats as their defaults, since the file could be for either" do
      first = format("First", created_at: 3.days.ago)
      second = format("Second", created_at: 1.day.ago)
      account("Chequing", default: first)
      visa = account("Visa", default: second)
      create(:budget_import, account: visa, csv_format: second, created_at: 1.hour.ago)

      result = guess

      expect(result).to be_format_certain
      expect(result).not_to be_account_certain
      expect(result).not_to be_complete
      expect(result.account).to eq(visa)
      expect(result.csv_format).to eq(second)
    end

    it "doesn't treat formats that read it differently as one: only the offered format's Accounts are looked at" do
      format("Plain", created_at: 1.day.ago)
      inverted = format("Inverted", invert_sign: true, created_at: 1.minute.from_now)
      account("Chequing", default: Budget::CsvFormat.find_by!(name: "Plain"))
      visa = account("Visa", default: inverted)

      result = guess

      expect(result.csv_format).to eq(inverted)
      expect(result.account).to eq(visa)
      expect(result).not_to be_format_certain
    end

    it "uses only the budget's own CSV formats and Accounts" do
      theirs = create(:budget_csv_format)
      create(:budget_account, budget: theirs.budget, default_csv_format: theirs)
      td = format("TD CSV")
      chequing = account("Chequing", default: td)

      result = guess

      expect(result.csv_format).to eq(td)
      expect(result.account).to eq(chequing)
      expect(result).to be_complete
    end
  end

  describe "a format that isn't certain" do
    it "is offered when two formats read the file cleanly but differently, as the one the most recent Import used, and is not complete" do
      plain = format("Plain")
      inverted = format("Inverted", invert_sign: true)
      create(:budget_import, account: account("Other"), csv_format: inverted, created_at: 1.hour.ago)
      create(:budget_import, account: account("Other too"), csv_format: plain, created_at: 2.days.ago)
      account("Chequing", default: inverted)

      result = guess

      expect(result.csv_format).to eq(inverted)
      expect(result).not_to be_format_certain
      expect(result).not_to be_complete
    end

    it "is the newest format when none of those that read it differently has been used" do
      format("Plain", created_at: 2.days.ago)
      newer = format("Inverted", invert_sign: true, created_at: 1.day.ago)

      result = guess

      expect(result.csv_format).to eq(newer)
      expect(result).not_to be_format_certain
    end

    it "still says which Account it would be, from the format that's offered, but is never complete" do
      format("Plain")
      inverted = format("Inverted", invert_sign: true, created_at: 1.minute.from_now)
      chequing = account("Chequing", default: inverted)

      result = guess

      expect(result.csv_format).to eq(inverted)
      expect(result.account).to eq(chequing)
      expect(result).to be_account_certain
      expect(result).not_to be_complete
    end

    it "counts only formats that read it cleanly, so a format that refuses doesn't make the others uncertain" do
      plain = format("Plain")
      format("Four columns", column_count: 4)
      format("Dates the other way", date_order: "month_day_year")

      result = guess

      expect(result.csv_format).to eq(plain)
      expect(result).to be_format_certain
    end
  end

  describe "an Account that isn't certain" do
    it "is none when no Account has the format as its default: the format is certain, and the guess isn't complete" do
      td = format("TD CSV")
      account("Chequing")

      result = guess

      expect(result.csv_format).to eq(td)
      expect(result).to be_format_certain
      expect(result.account).to be_nil
      expect(result).not_to be_account_certain
      expect(result).not_to be_complete
    end

    it "is the one imported into most recently when several have the format as their default, which isn't complete: duplicates are judged per Account" do
      td = format("TD CSV")
      older = account("Chequing", default: td)
      recent = account("Visa", default: td)
      third = account("Savings", default: td)
      create(:budget_import, account: older, csv_format: td, created_at: 3.days.ago)
      create(:budget_import, account: recent, csv_format: td, created_at: 1.hour.ago)
      create(:budget_import, account: third, csv_format: td, created_at: 2.days.ago)

      result = guess

      expect(result.account).to eq(recent)
      expect(result).to be_format_certain
      expect(result).not_to be_account_certain
      expect(result).not_to be_complete
    end

    it "is the first alphabetically when none of them has had an Import" do
      td = format("TD CSV")
      account("Visa", default: td)
      chequing = account("Chequing", default: td)

      result = guess

      expect(result.account).to eq(chequing)
      expect(result).not_to be_account_certain
    end

    it "does not count an Account whose Import used another format, only its default" do
      td = format("TD CSV")
      other = format("Other", column_count: 4)
      only = account("Chequing", default: td)
      create(:budget_import, account: account("Visa", default: other), csv_format: td)

      result = guess

      expect(result.account).to eq(only)
      expect(result).to be_account_certain
    end
  end

  describe "when no CSV format reads the file" do
    it "has no format, no Account, and each format's first refusal, in its own words, alphabetically" do
      td = format("TD CSV", date_order: "day_month_year")
      amex = format("Amex", column_count: 4)
      account("Chequing", default: td)

      result = guess("2026-09-01,Paycheck,2800.00\n")

      expect(result.csv_format).to be_nil
      expect(result.account).to be_nil
      expect(result).not_to be_complete
      expect(result.file_refusal).to be_nil
      expect(result.refusals.map(&:csv_format)).to eq([ amex, td ])
      expect(result.refusals.map { |rejection| rejection.refusal.message }).to eq([
        "Line 1: has 3 columns, and this CSV format expects 4.",
        "Line 1: the date \"2026-09-01\" isn't a date in day, month, year order."
      ])
    end

    it "says what's wrong with the file when every format would, once, and doesn't list the formats" do
      format("TD CSV")
      format("Amex", column_count: 4)

      [ "", "\n\n", "2026-09-01,\"Loblaws,-5.00\n", "2026-09-01,Caf\xE9,-5.00\n".b ].each do |text|
        result = guess(text)

        expect(result.csv_format).to be_nil
        expect(result.file_refusal).to be_about_the_file
        expect(result).not_to be_complete
      end
    end

    it "says the file is over 2 MB, or not UTF-8, without reading it with any format" do
      format("TD CSV")

      expect(guess("2026-09-01,#{"x" * 2.megabytes},-5.00\n").file_refusal.message).to eq("The file is over 2 MB.")
      expect(guess("2026-09-01,Caf\xE9,-5.00\n".b).file_refusal.message).to eq("The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again.")
      expect(guess("2026-09-01,Caf\xE9,-5.00\n".b).refusals).to eq([])
    end

    it "lists the formats' refusals when only some are the file's: each format's own first refusal" do
      format("TD CSV")
      format("Amex", column_count: 4)

      result = guess("2026-09-01,Paycheck\n")

      expect(result.file_refusal).to be_nil
      expect(result.refusals.size).to eq(2)
    end

    it "has no format when the budget has none, and no refusals" do
      result = guess

      expect(result.csv_format).to be_nil
      expect(result.refusals).to eq([])
      expect(result.file_refusal).to be_nil
      expect(result).not_to be_complete
    end
  end

  describe "reading the file" do
    it "reads it once, whatever number of formats there are, and from an upload or its text" do
      reads = 0
      upload = StringIO.new(file).tap { |io| io.define_singleton_method(:read) { |*args| reads += 1; super(*args) } }
      3.times { |n| format("Format #{n}", column_count: 3 + n) }

      result = Budget::ImportGuesser.new(budget).guess(upload)

      expect(reads).to eq(1)
      expect(result.csv_format).to be_present
      expect(guess(file).csv_format).to eq(result.csv_format)
    end

    it "never reads past the first row with a format that doesn't fit, which costs no more than a refusal" do
      format("Four columns", column_count: 4)
      big = "2026-09-01,Coffee shop,-1.00\n" * 5000
      expect_any_instance_of(Budget::CsvFormat::Reader).to receive(:read_row).once.and_call_original

      result = guess(big)

      expect(result.refusals.sole.refusal.line).to eq(1)
    end

    it "makes the same number of queries for a file of 10 rows as for 5,000, and for formats that fit or not" do
      td = format("TD CSV")
      format("Inverted", invert_sign: true)
      format("Four columns", column_count: 4)
      account("Chequing", default: td)
      account("Visa", default: td)
      small = "2026-09-01,Coffee shop,-1.00\n" * 10
      big = "2026-09-01,Coffee shop,-1.00\n" * 5000

      guess(small)
      few = count_queries { guess(small) }
      many = count_queries { guess(big) }

      expect(many).to eq(few)
      expect(few).to be <= 6
    end

    it "creates and changes nothing" do
      td = format("TD CSV")
      account("Chequing", default: td)

      expect { guess }.not_to change { [ Budget::Import.count, Budget::BankTransaction.count, Budget::Account.count, Budget::CsvFormat.count ] }
    end
  end
end
