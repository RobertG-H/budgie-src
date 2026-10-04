require "rails_helper"

RSpec.describe Budget::Import, type: :model do
  subject { build(:budget_import) }

  it { is_expected.to belong_to(:account).class_name("Budget::Account") }
  it { is_expected.to belong_to(:csv_format).class_name("Budget::CsvFormat") }
  it { is_expected.to have_many(:bank_transactions).class_name("Budget::BankTransaction").dependent(:restrict_with_error) }

  it "uses the budget_imports table, and is named without the Budget prefix in routes and params" do
    expect(Budget::Import.table_name).to eq("budget_imports")
    expect(Budget::Import.model_name).to have_attributes(route_key: "imports", param_key: "import")
  end

  it "has no user, since authorship is decided once for every record" do
    expect(Budget::Import.column_names).not_to include("user_id")
  end

  describe "validations" do
    it "needs a file name, which is all that's kept of the file" do
      import = build(:budget_import, file_name: " ")

      expect(import).not_to be_valid
      expect(import.errors.full_messages).to eq([ "File name can't be blank" ])
    end

    it "needs a CSV format, and one of the Account's own budget" do
      expect(build(:budget_import, csv_format: nil)).not_to be_valid

      import = build(:budget_import, csv_format: create(:budget_csv_format))

      expect(import).not_to be_valid
      expect(import.errors.full_messages).to eq([ "CSV format must be in the same budget as the account" ])
    end

    it "counts what it skipped as 0 or more" do
      expect(build(:budget_import, duplicates_skipped: -1)).not_to be_valid
      expect(build(:budget_import, zero_rows_skipped: -1)).not_to be_valid
    end
  end

  describe ".latest_first" do
    it "orders by when they ran, newest first, and by the order they were made in at the same moment" do
      account = create(:budget_account)
      moment = Time.zone.local(2026, 9, 15, 10)
      oldest = create(:budget_import, account: account, created_at: moment - 1.day)
      first = create(:budget_import, account: account, created_at: moment)
      second = create(:budget_import, account: account, created_at: moment)

      expect(account.imports.latest_first).to eq([ second, first, oldest ])
    end
  end

  describe "database constraints" do
    let(:import) { create(:budget_import) }

    def update_import(import, assignments)
      Budget::Import.transaction(requires_new: true) { Budget::Import.where(id: import.id).update_all(assignments) }
    end

    it "rejects a blank file name" do
      expect { update_import(import, "file_name = '  '") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_file_name_not_blank/)
    end

    it "rejects a negative count of what it skipped" do
      expect { update_import(import, "duplicates_skipped = -1") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_duplicates_skipped_not_negative/)
      expect { update_import(import, "zero_rows_skipped = -1") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_zero_rows_skipped_not_negative/)
    end

    %w[ account_id csv_format_id file_name duplicates_skipped zero_rows_skipped ].each do |column|
      it "requires a #{column}" do
        expect { update_import(import, "#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "keeps a CSV format that has an Import from being deleted without it" do
      expect { Budget::CsvFormat.where(id: import.csv_format_id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end

    it "keeps an Account that has an Import from being deleted without it" do
      expect { Budget::Account.where(id: import.account_id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end

  describe "#run" do
    let(:account) { create(:budget_account) }
    # A date, a description and a signed amount, with no header.
    let(:csv_format) { create(:budget_csv_format, budget: account.budget) }

    def import_of(text, account: self.account, csv_format: self.csv_format, file_name: "september.csv")
      account.imports.build(csv_format: csv_format, file_name: file_name).tap { |import| import.run(text) }
    end

    def rows_of(account)
      account.bank_transactions.order(:id).pluck(:date, :description, :amount, :occurrence)
    end

    let(:september) do
      <<~CSV
        2026-09-01,Paycheck,2800.00
        2026-09-02,Loblaws,-82.45
        2026-09-02,Coffee shop,-4.25
        2026-09-02,Coffee shop,-4.25
      CSV
    end

    describe "a file that's read" do
      it "creates an Import, with the file's name, and a bank transaction for each row, signed" do
        import = nil

        expect { import = import_of(september) }.to change(Budget::Import, :count).by(1).and change(Budget::BankTransaction, :count).by(4)

        expect(import).to be_persisted
        expect(import).to have_attributes(account: account, csv_format: csv_format, file_name: "september.csv", duplicates_skipped: 0, zero_rows_skipped: 0)
        expect(import.bank_transactions.order(:id).pluck(:date, :description, :amount)).to eq([
          [ Date.new(2026, 9, 1), "Paycheck", 2800 ], [ Date.new(2026, 9, 2), "Loblaws", BigDecimal("-82.45") ],
          [ Date.new(2026, 9, 2), "Coffee shop", BigDecimal("-4.25") ], [ Date.new(2026, 9, 2), "Coffee shop", BigDecimal("-4.25") ]
        ])
      end

      it "returns true, and false when it can't" do
        import = account.imports.build(csv_format: csv_format, file_name: "september.csv")

        expect(import.run(september)).to be(true)
        expect(account.imports.build(csv_format: csv_format, file_name: "bad.csv").run("nope,Paycheck,2800.00\n")).to be(false)
      end

      it "gives the rows the content key and occurrence of what each one is in its Account" do
        import_of(september)

        coffee = account.bank_transactions.where(description: "Coffee shop").order(:occurrence)
        expect(coffee.pluck(:occurrence)).to eq([ 1, 2 ])
        expect(coffee.first.content_key).to eq(Budget::BankTransaction.content_key(account_id: account.id, date: Date.new(2026, 9, 2), amount: BigDecimal("-4.25"), description: "Coffee shop"))
        expect(coffee.first.content_key).to eq(coffee.last.content_key)
      end

      it "reads with the CSV format it was given, in any of its amount styles" do
        format = create(:budget_csv_format, :in_and_out, budget: account.budget)

        import_of("2026-09-01,Paycheck,,2800.00\n2026-09-02,Loblaws,82.45,\n", csv_format: format)

        expect(rows_of(account).map { |row| row[2] }).to eq([ 2800, BigDecimal("-82.45") ])
      end
    end

    describe "a file that can't be read" do
      it "creates no Import and no bank transactions, and says which row, and why" do
        import = nil

        expect { import = import_of("2026-09-01,Paycheck,2800.00\n2026-09-02,Loblaws,abc\n") }
          .to not_change(Budget::Import, :count).and not_change(Budget::BankTransaction, :count)

        expect(import).not_to be_persisted
        expect(import.errors.full_messages).to eq([ "Line 2: the amount \"abc\" isn't a number." ])
      end

      it "says so for a file that's too big, or isn't UTF-8, or has no rows" do
        expect(import_of("2026-09-01,Caf\xE9,-5.00\n".b).errors.full_messages).to eq([ "The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again." ])
        expect(import_of("").errors.full_messages).to eq([ "There are no rows to read after the rows to skip." ])
        expect(Budget::Import.count).to eq(0)
      end

      it "is refused without a file, and without a name for it" do
        import = account.imports.build(csv_format: csv_format, file_name: "september.csv")

        expect(import.run(nil)).to be(false)
        expect(import.errors.full_messages).to eq([ "Choose a file to import." ])

        import = account.imports.build(csv_format: csv_format, file_name: "")
        expect(import.run(september)).to be(false)
        expect(import.errors.full_messages).to eq([ "File name can't be blank" ])
        expect(Budget::Import.count).to eq(0)
      end

      it "is refused with another budget's CSV format, and reads nothing with it" do
        others = create(:budget_csv_format)
        import = account.imports.build(csv_format: others, file_name: "september.csv")

        expect(import.run(september)).to be(false)
        expect(import.errors.full_messages).to eq([ "CSV format must be in the same budget as the account" ])
        expect(Budget::BankTransaction.count).to eq(0)
      end

      it "is refused without a CSV format" do
        import = account.imports.build(csv_format: nil, file_name: "september.csv")

        expect(import.run(september)).to be(false)
        expect(import.errors.full_messages).to eq([ "CSV format can't be blank" ])
      end
    end

    describe "rows of 0" do
      it "are skipped, and counted" do
        import = import_of("2026-09-01,Paycheck,2800.00\n2026-09-02,Interest,0.00\n2026-09-03,Interest,0.00\n")

        expect(import.zero_rows_skipped).to eq(2)
        expect(rows_of(account).map { |row| row[1] }).to eq([ "Paycheck" ])
      end

      it "alone make an Import of no bank transactions, which is kept" do
        import = import_of("2026-09-02,Interest,0.00\n")

        expect(import).to be_persisted
        expect(import).to have_attributes(zero_rows_skipped: 1, duplicates_skipped: 0)
        expect(account.bank_transactions).to be_empty
      end
    end

    describe "duplicates (ADR 0010)" do
      it "brings in two identical coffees on one day from one file, as occurrences 1 and 2" do
        import_of(september)

        expect(rows_of(account).select { |row| row[1] == "Coffee shop" }.map(&:last)).to eq([ 1, 2 ])
      end

      it "adds nothing when the same file is imported again, and counts every row it skipped" do
        import_of(september)

        again = nil
        expect { again = import_of(september) }.to change(Budget::Import, :count).by(1).and not_change(Budget::BankTransaction, :count)

        expect(again).to have_attributes(duplicates_skipped: 4, zero_rows_skipped: 0)
        expect(again.bank_transactions).to be_empty
      end

      it "adds only the rows past the overlap, when an overlapping file is imported" do
        import_of("2026-09-01,Paycheck,2800.00\n2026-09-02,Loblaws,-82.45\n")

        overlapping = import_of("2026-09-02,Loblaws,-82.45\n2026-09-03,Hydro,-65.50\n2026-09-04,Coffee shop,-4.25\n")

        expect(overlapping.duplicates_skipped).to eq(1)
        expect(overlapping.bank_transactions.order(:id).pluck(:description)).to eq([ "Hydro", "Coffee shop" ])
        expect(account.bank_transactions.count).to eq(4)
      end

      it "adds one, numbered 3, when a file with three identical rows is imported into an Account that already has two of them" do
        import_of("2026-09-02,Coffee shop,-4.25\n2026-09-02,Coffee shop,-4.25\n")

        third = import_of("2026-09-02,Coffee shop,-4.25\n2026-09-02,Coffee shop,-4.25\n2026-09-02,Coffee shop,-4.25\n")

        expect(third.duplicates_skipped).to eq(2)
        expect(third.bank_transactions.pluck(:occurrence)).to eq([ 3 ])
        expect(account.bank_transactions.where(description: "Coffee shop").order(:occurrence).pluck(:occurrence)).to eq([ 1, 2, 3 ])
      end

      it "counts the rows of every earlier Import, not just the latest" do
        import_of("2026-09-02,Coffee shop,-4.25\n")
        import_of("2026-09-02,Coffee shop,-4.25\n2026-09-02,Coffee shop,-4.25\n")

        third = import_of("2026-09-02,Coffee shop,-4.25\n2026-09-02,Coffee shop,-4.25\n")

        expect(third).to have_attributes(duplicates_skipped: 2)
        expect(third.bank_transactions).to be_empty
      end

      it "treats a row that differs only in case, spacing or surrounding space as the same row" do
        import_of("2026-09-02,Loblaws #1234,-82.45\n")

        again = import_of("2026-09-02,  LOBLAWS   #1234 ,-82.45\n")

        expect(again.duplicates_skipped).to eq(1)
      end

      it "treats a row that differs in its date, amount, sign or description as another row" do
        import_of("2026-09-02,Loblaws,-82.45\n")

        other = import_of("2026-09-03,Loblaws,-82.45\n2026-09-02,Loblaws,-82.46\n2026-09-02,Loblaws,82.45\n2026-09-02,Loblaws Inc,-82.45\n")

        expect(other.duplicates_skipped).to eq(0)
        expect(other.bank_transactions.count).to eq(4)
      end

      it "doesn't count another Account's rows, since each Account has its own" do
        other = create(:budget_account, budget: account.budget)
        import_of(september, account: other)

        mine = import_of(september)

        expect(mine.duplicates_skipped).to eq(0)
        expect(account.bank_transactions.count).to eq(4)
        expect(other.bank_transactions.count).to eq(4)
      end

      it "imports a double submit once, since the second finds every row a duplicate" do
        first = import_of(september)
        second = import_of(september)

        expect(first.bank_transactions.count).to eq(4)
        expect(second).to have_attributes(duplicates_skipped: 4)
        expect(account.bank_transactions.count).to eq(4)
      end

      it "keeps the content key and occurrence a row was brought in with, since they record how it first looked" do
        import_of("2026-09-02,Loblaws,-82.45\n")
        transaction = account.bank_transactions.sole
        key, occurrence = transaction.content_key, transaction.occurrence
        transaction.update!(description: "LOBLAWS #1234 TORONTO")

        import_of("2026-09-02,Loblaws,-82.45\n")

        expect(account.bank_transactions.count).to eq(1)
        expect(transaction.reload).to have_attributes(content_key: key, occurrence: occurrence)
      end
    end

    describe "the number of queries" do
      def file_of(rows)
        (1..rows).map { |n| "2026-09-#{format("%02d", (n % 28) + 1)},Merchant #{n},-#{n}.25\n" }.join
      end

      it "is the same for 10 rows as for 1,000, with half of each already in the Account" do
        small_account = create(:budget_account, budget: account.budget)
        large_account = create(:budget_account, budget: account.budget)
        import_of(file_of(5), account: small_account)
        import_of(file_of(500), account: large_account)

        small = count_queries { import_of(file_of(10), account: small_account) }
        large = count_queries { import_of(file_of(1000), account: large_account) }

        expect(large).to eq(small)
        expect(small_account.bank_transactions.count).to eq(10)
        expect(large_account.bank_transactions.count).to eq(1000)
      end
    end
  end
end
