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

    it "counts what it skipped, and what Filing rules filed and ignored, as 0 or more" do
      expect(build(:budget_import, duplicates_skipped: -1)).not_to be_valid
      expect(build(:budget_import, zero_rows_skipped: -1)).not_to be_valid
      expect(build(:budget_import, filed_by_rules: -1)).not_to be_valid
      expect(build(:budget_import, ignored_by_rules: -1)).not_to be_valid
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

    describe "what the file held" do
      let(:import) { create(:budget_import, earliest_date: Date.new(2026, 9, 1), latest_date: Date.new(2026, 9, 2), money_in_count: 1, money_in_total: 10,
        money_out_count: 1, money_out_total: -5, first_row_date: Date.new(2026, 9, 1), first_row_description: "Paycheck", first_row_amount: 10) }

      it "is consistent as made" do
        expect(import.reload).to be_persisted
      end

      it "rejects negative counts, a money in total that isn't positive when there's some, and a money out total that isn't negative" do
        expect { update_import(import, "money_in_count = -1, money_out_count = 0, money_out_total = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_money_counts_not_negative/)
        expect { update_import(import, "money_in_total = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_money_in_total_matches_count/)
        expect { update_import(import, "money_in_total = -10") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_money_in_total_matches_count/)
        expect { update_import(import, "money_out_total = 5") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_money_out_total_matches_count/)
        expect { update_import(import, "money_out_count = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_money_out_total_matches_count/)
      end

      it "rejects dates that aren't there when there are rows, are there when there aren't, or run backwards" do
        expect { update_import(import, "earliest_date = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_dates_match_rows/)
        expect { update_import(import, "earliest_date = '2026-09-03'") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_dates_match_rows/)
        expect { update_import(create(:budget_import), "earliest_date = '2026-09-01', latest_date = '2026-09-01'") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_dates_match_rows/)
      end

      it "rejects a first row that's partly there, blank, of 0, or there when the file had no rows" do
        expect { update_import(import, "first_row_description = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_first_row_matches_rows/)
        expect { update_import(import, "first_row_description = ' '") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_first_row_matches_rows/)
        expect { update_import(import, "first_row_amount = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_first_row_matches_rows/)
        expect { update_import(import, "first_row_date = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_imports_first_row_matches_rows/)
        expect { update_import(create(:budget_import), "first_row_date = '2026-09-01', first_row_description = 'x', first_row_amount = 1") }
          .to raise_error(ActiveRecord::CheckViolation, /budget_imports_first_row_matches_rows/)
      end
    end

    %w[ account_id csv_format_id file_name duplicates_skipped zero_rows_skipped money_in_count money_in_total money_out_count money_out_total ].each do |column|
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

      it "imports a row the bank gave no description as No description, which is filed, ignored or matched like any other" do
        import = import_of("2026-09-01,Paycheck,2800.00\n2026-09-02,,-250.00\n2026-09-03,,-250.00\n")

        expect(import).to be_persisted
        expect(rows_of(account)).to eq([ [ Date.new(2026, 9, 1), "Paycheck", 2800, 1 ], [ Date.new(2026, 9, 2), "No description", -250, 1 ],
                                         [ Date.new(2026, 9, 3), "No description", -250, 1 ] ])

        row = account.bank_transactions.find_by!(date: Date.new(2026, 9, 2)).reload
        envelope = create(:budget_envelope, budget: account.budget, name: "Card")
        entry = Budget::Filing::Entry.new(bank_transaction: row, drafts: [ Budget::Filing::Draft.for(row, envelope_id: envelope.id) ])

        expect(Budget::Filing.new(account.budget).file([ entry ])).to be(true)
        expect(envelope.spends.sole).to have_attributes(description: "No description", amount: 250)

        rule = create(:budget_filing_rule, :ignore, budget: account.budget, text: "no description")
        other = account.bank_transactions.find_by!(date: Date.new(2026, 9, 3)).reload
        expect(rule.fits?(other)).to be(true)
      end

      it "counts the same row twice in a file as two, as it does any other, and skips it when the file is imported again" do
        text = "2026-09-02,,-250.00\n2026-09-02,,-250.00\n"
        import_of(text)

        expect(rows_of(account).map(&:last)).to eq([ 1, 2 ])
        expect(import_of(text).duplicates_skipped).to eq(2)
        expect(account.bank_transactions.count).to eq(2)
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

    describe "what the file held, which its summary says without the file" do
      it "is the dates it spans, how many rows were money in and money out and what each adds up to, and its first row as it was read" do
        import = import_of(september)

        expect(import).to have_attributes(
          earliest_date: Date.new(2026, 9, 1), latest_date: Date.new(2026, 9, 2),
          money_in_count: 1, money_in_total: 2800, money_out_count: 3, money_out_total: BigDecimal("-90.95"),
          first_row_date: Date.new(2026, 9, 1), first_row_description: "Paycheck", first_row_amount: 2800
        )
        expect(import.reload).to have_attributes(money_out_total: BigDecimal("-90.95"), first_row_description: "Paycheck")
      end

      it "is of the whole file, so an overlapping file's figures include the rows that were already there" do
        import_of("2026-09-01,Paycheck,2800.00\n2026-09-02,Loblaws,-82.45\n")

        overlapping = import_of("2026-09-02,Loblaws,-82.45\n2026-09-03,Hydro,-65.50\n2026-09-04,Gym,-30.00\n")

        expect(overlapping).to have_attributes(
          duplicates_skipped: 1, earliest_date: Date.new(2026, 9, 2), latest_date: Date.new(2026, 9, 4),
          money_in_count: 0, money_in_total: 0, money_out_count: 3, money_out_total: BigDecimal("-177.95"),
          first_row_description: "Loblaws", first_row_amount: BigDecimal("-82.45")
        )
        expect(overlapping.added_count).to eq(2)
      end

      it "is still there when nothing was added, since the same file read again is the same file" do
        import_of(september)

        again = import_of(september)

        expect(again).to have_attributes(duplicates_skipped: 4, added_count: 0, earliest_date: Date.new(2026, 9, 1), money_out_count: 3, first_row_description: "Paycheck")
      end

      it "has no dates and no first row for a file of nothing but rows of 0, and counts nothing" do
        import = import_of("2026-09-02,Interest,0.00\n")

        expect(import).to have_attributes(earliest_date: nil, latest_date: nil, first_row_date: nil, first_row_description: nil, first_row_amount: nil,
          money_in_count: 0, money_in_total: 0, money_out_count: 0, money_out_total: 0, added_count: 0)
        expect(import.first_row).to be_nil
      end

      it "reads the first row after the rows to skip, and as the CSV format read it, with the sign inverted" do
        format = create(:budget_csv_format, budget: account.budget, rows_to_skip: 1, invert_sign: true)

        import = import_of("Date,Description,Amount\n2026-09-05,Gym,-30.00\n2026-09-06,Refund,5.00\n", csv_format: format)

        expect(import.first_row).to have_attributes(date: Date.new(2026, 9, 5), description: "Gym", amount: 30)
        expect(import).to have_attributes(money_in_count: 1, money_in_total: 30, money_out_count: 1, money_out_total: -5)
      end

      it "counts what was added, which is the rows of the file less the ones already there, and is what Undo would delete" do
        import = import_of(september)
        again = import_of("2026-09-01,Paycheck,2800.00\n2026-09-05,Gym,-30.00\n")

        expect(import.added_count).to eq(4)
        expect(again.added_count).to eq(1)
        expect(again.duplicates_skipped).to eq(1)
        expect { again.undo }.to change(Budget::BankTransaction, :count).by(-again.added_count)
      end

      it "is nothing for a file that's refused, which creates no Import" do
        import = import_of("2026-09-01,Paycheck,2800.00\n2026-13-45,Loblaws,-82.45\n")

        expect(import).not_to be_persisted
        expect(import.money_in_count).to eq(0)
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

    # Filing rules act on the rows an Import creates, inside its one database transaction, straight away (ADR 0012).
    describe "Filing rules" do
      let(:budget) { account.budget }
      let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }

      def rule(text, *traits, **attributes)
        create(:budget_filing_rule, *traits, **{ budget: budget, envelope: groceries, text: text }.merge(attributes))
      end

      it "file and ignore the rows they fit, with the rule noted on each, and say how many in the Import" do
        loblaws = rule("loblaws")
        payment = rule("payment thank you", :ignore)

        import = import_of("2026-09-01,Paycheck,2800.00\n2026-09-02,LOBLAWS #1234,-82.45\n2026-09-03,PAYMENT THANK YOU,-250.00\n2026-09-04,Loblaws,-10.00\n")

        expect(import).to have_attributes(filed_by_rules: 2, ignored_by_rules: 1)
        expect(import.reload).to have_attributes(filed_by_rules: 2, ignored_by_rules: 1)
        rows = account.bank_transactions.index_by(&:description)
        expect(rows["Paycheck"]).to be_unfiled
        expect(rows["LOBLAWS #1234"]).to be_filed.and have_attributes(filing_rule_id: loblaws.id)
        expect(rows["Loblaws"]).to be_filed.and have_attributes(filing_rule_id: loblaws.id)
        expect(rows["PAYMENT THANK YOU"]).to be_ignored.and have_attributes(filing_rule_id: payment.id)
        expect(groceries.spends.pluck(:description, :date, :amount)).to contain_exactly(
          [ "LOBLAWS #1234", Date.new(2026, 9, 2), BigDecimal("82.45") ], [ "Loblaws", Date.new(2026, 9, 4), 10 ]
        )
      end

      it "still count every row as added, since they're bank transactions that were filed" do
        rule("loblaws")

        import = import_of("2026-09-02,Loblaws,-82.45\n2026-09-03,Rent,-1500.00\n")

        expect(import.added_count).to eq(2)
      end

      it "use the most specific rule that fits a row" do
        household = create(:budget_envelope, budget: budget, name: "Household")
        rule("loblaws")
        specific = rule("loblaws #1234", envelope: household)

        import_of("2026-09-02,LOBLAWS #1234 TORONTO,-82.45\n")

        expect(household.spends.sole.bank_transaction.filing_rule_id).to eq(specific.id)
        expect(groceries.spends).to be_empty
      end

      it "fit a Deposit and a Refund to money in, and a rule's sign has to suit the row" do
        rule("payroll", :deposit)
        rule("loblaws", :refund)

        import_of("2026-09-01,ACME PAYROLL,2800.00\n2026-09-02,LOBLAWS RETURN,18.75\n2026-09-03,PAYROLL ADJUSTMENT,-50.00\n")

        expect(budget.deposits.sole).to have_attributes(description: "ACME PAYROLL", amount: 2800)
        expect(groceries.refunds.sole).to have_attributes(description: "LOBLAWS RETURN", amount: BigDecimal("18.75"))
        expect(account.bank_transactions.find_by!(description: "PAYROLL ADJUSTMENT")).to be_unfiled
      end

      it "do nothing for a rule on an archived envelope, until it's unarchived" do
        rule("loblaws")
        groceries.update!(archived_at: Time.current)

        import = import_of("2026-09-02,Loblaws,-82.45\n")

        expect(import).to have_attributes(filed_by_rules: 0, ignored_by_rules: 0)
        expect(account.bank_transactions.sole).to be_unfiled
      end

      it "are only the budget's own" do
        create(:budget_filing_rule, text: "loblaws")

        import_of("2026-09-02,Loblaws,-82.45\n")

        expect(account.bank_transactions.sole).to be_unfiled
      end

      it "don't touch the rows an Import skipped as duplicates, which are already there, filed or not" do
        first = import_of("2026-09-02,Loblaws,-82.45\n")
        expect(account.bank_transactions.sole).to be_unfiled

        rule("loblaws")
        second = import_of("2026-09-02,Loblaws,-82.45\n")

        expect(second).to have_attributes(duplicates_skipped: 1, filed_by_rules: 0)
        expect(account.bank_transactions.sole).to be_unfiled
        expect(first.bank_transactions.sole).to be_unfiled
      end

      it "don't file a file that can't be read, which creates nothing" do
        rule("loblaws")

        expect { import_of("2026-09-02,Loblaws,not an amount\n") }.not_to change(Budget::Spend, :count)
      end

      it "are undone with the Import, which deletes what they filed like any other filed records" do
        rule("loblaws")
        rule("payment thank you", :ignore)
        import = import_of("2026-09-02,Loblaws,-82.45\n2026-09-03,PAYMENT THANK YOU,-250.00\n")

        expect { import.undo }
          .to change(Budget::Spend, :count).by(-1).and change(Budget::SpendLink, :count).by(-1)
          .and change(Budget::BankTransaction, :count).by(-2).and change(Budget::Import, :count).by(-1)
      end

      it "are applied again to the same file after an Undo, since undone rows no longer count as there" do
        rule("loblaws")
        file = "2026-09-02,Loblaws,-82.45\n"
        import_of(file).undo

        again = import_of(file)

        expect(again).to have_attributes(duplicates_skipped: 0, filed_by_rules: 1)
        expect(groceries.spends.count).to eq(1)
      end

      it "make the same number of queries for 10 rows as for 1,000, and for 2 rules as for 100" do
        rule("alpha")
        rule("beta", :ignore)
        file_of = ->(count) { (1..count).map { |n| "2026-09-#{format("%02d", (n % 28) + 1)},#{n.odd? ? "alpha" : "beta"} #{n},-#{n}.25\n" }.join }
        warm_up, small_account, large_account, many_rules_account = Array.new(4) { create(:budget_account, budget: budget) }
        import_of(file_of.(4), account: warm_up)

        few = count_queries { import_of(file_of.(10), account: small_account) }
        many = count_queries { import_of(file_of.(1000), account: large_account) }

        # 98 more rules, half of them ignoring, and a row for each, so that every one of the 100 rules does something.
        texts = Array.new(98) { |n| "gamma #{format("%03d", n)}" }
        texts.each_with_index { |text, n| n.even? ? rule(text) : rule(text, :ignore) }
        gamma = texts.map { |text| "2026-09-01,#{text} x,-1.25\n" }.join
        with_many_rules = count_queries { import_of(gamma, account: many_rules_account) }

        expect(many).to eq(few)
        expect(with_many_rules).to eq(few)
        expect(large_account.bank_transactions.where.not(filing_rule_id: nil).count).to eq(1000)
        expect(many_rules_account.bank_transactions.where.not(filing_rule_id: nil).distinct.count(:filing_rule_id)).to eq(98)
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

  describe "undoing (ADR 0011)" do
    let(:account) { create(:budget_account) }
    let(:csv_format) { create(:budget_csv_format, budget: account.budget) }
    let(:file) { "2026-09-01,Paycheck,2800.00\n2026-09-02,Loblaws,-82.45\n" }

    def import_of(text, created_at: Time.current)
      travel_to(created_at) { account.imports.build(csv_format: csv_format, file_name: "sept.csv").tap { |import| import.run(text) } }
    end

    it "deletes the Account's latest Import and its bank transactions, which is all it deletes" do
      earlier = import_of("2026-08-01,Rent,-1500.00\n", created_at: 3.days.ago)
      import = import_of(file)
      others = create(:budget_bank_transaction)

      expect { import.undo }.to change(Budget::Import, :count).by(-1).and change(Budget::BankTransaction, :count).by(-2)

      expect(Budget::Import.exists?(import.id)).to be(false)
      expect(account.imports).to contain_exactly(earlier)
      expect(account.bank_transactions.pluck(:description)).to eq([ "Rent" ])
      expect(Budget::BankTransaction.where(id: others.id)).to exist
      expect(Budget::Import.where(id: others.import_id)).to exist
    end

    describe "with bank transactions that have been filed" do
      let(:groceries) { create(:budget_envelope, budget: account.budget, name: "Groceries") }

      def file_as_spend(bank_transaction, amount)
        create(:budget_spend_link, bank_transaction: bank_transaction, spend: create(:budget_spend, envelope: groceries, date: Date.new(2026, 9, 2), amount: amount))
      end

      it "deletes the records they were filed as and their links first, then the bank transactions, then the Import, and the month's figures go back" do
        import = import_of(file)
        month = -> { Budget::Month.new(account.budget, Date.new(2026, 9, 1)).envelope_line(groceries.id) }
        before = month.call.available
        file_as_spend(import.bank_transactions.find_by!(description: "Loblaws"), BigDecimal("82.45"))
        expect(month.call.available).to eq(before - BigDecimal("82.45"))

        expect { import.undo }
          .to change(Budget::Spend, :count).by(-1).and change(Budget::SpendLink, :count).by(-1)
          .and change(Budget::BankTransaction, :count).by(-2).and change(Budget::Import, :count).by(-1)

        expect(month.call.available).to eq(before)
        expect(month.call.spent).to eq(0)
      end

      it "deletes records of every kind, and leaves the records of other Imports and other Accounts alone" do
        earlier = import_of("2026-08-01,Rent,-1500.00\n", created_at: 3.days.ago)
        file_as_spend(earlier.bank_transactions.sole, 1500)
        import = import_of(file)
        paycheck = import.bank_transactions.find_by!(description: "Paycheck")
        create(:budget_deposit_link, bank_transaction: paycheck, deposit: create(:budget_deposit, budget: account.budget, amount: 2800))
        file_as_spend(import.bank_transactions.find_by!(description: "Loblaws"), BigDecimal("82.45"))
        others = create(:budget_bank_transaction, :filed)

        expect { import.undo }.to change(Budget::Deposit, :count).by(-1).and change(Budget::Spend, :count).by(-1)

        expect(earlier.bank_transactions.sole).to be_filed
        expect(others.reload).to be_filed
        expect(Budget::SpendLink.count).to eq(2)
      end

      it "counts the records it will delete, of each kind, for the confirmation" do
        import = import_of(file)
        file_as_spend(import.bank_transactions.find_by!(description: "Loblaws"), BigDecimal("82.45"))
        create(:budget_deposit_link, bank_transaction: import.bank_transactions.find_by!(description: "Paycheck"), deposit: create(:budget_deposit, budget: account.budget, amount: 2800))
        create(:budget_spend_link, bank_transaction: create(:budget_bank_transaction, :filed).tap { |other| other }, spend: create(:budget_spend, envelope: groceries, amount: 5)) # Someone else's.

        expect(import.filed_record_counts).to eq(deposits: 1, spends: 1, refunds: 0)
        expect(import.filed_record_counts.values.sum).to eq(2)
      end

      it "is all or nothing, so a record that can't be deleted keeps everything" do
        import = import_of(file)
        file_as_spend(import.bank_transactions.find_by!(description: "Loblaws"), BigDecimal("82.45"))
        allow(import).to receive(:destroy!).and_raise(ActiveRecord::StatementInvalid, "the database went away")

        expect { import.undo }.to raise_error(ActiveRecord::StatementInvalid)

        expect(Budget::Spend.count).to eq(1)
        expect(Budget::SpendLink.count).to eq(1)
        expect(import.bank_transactions.count).to eq(2)
      end
    end

    it "takes the Account's row lock, so an Import can't land while it's running" do
      import = import_of(file)
      statements = []
      collector = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(collector, "sql.active_record") { import.undo }

      expect(statements.grep(/FROM "budget_accounts".*FOR UPDATE/m)).not_to be_empty
    end

    it "deletes everything or nothing" do
      import = import_of(file)
      allow(import).to receive(:destroy!).and_raise(ActiveRecord::StatementInvalid, "the database went away")

      expect { import.undo }.to raise_error(ActiveRecord::StatementInvalid)

      expect(import.bank_transactions.count).to eq(2)
      expect(Budget::Import.exists?(import.id)).to be(true)
    end

    describe "within 24 hours of it running" do
      it "is allowed right up to 24 hours" do
        import = import_of(file, created_at: Time.zone.local(2026, 9, 15, 10))

        travel_to(import.created_at + 24.hours) { expect(import.undo_refusal).to be_nil }
      end

      it "is refused a minute after 24 hours, saying so, and changes nothing" do
        import = import_of(file, created_at: Time.zone.local(2026, 9, 15, 10))

        travel_to(import.created_at + 24.hours + 1.minute) do
          expect { import.undo }.to raise_error(Budget::Import::Refused, "This Import ran more than 24 hours ago, so it can't be undone.")
        end

        expect(import.bank_transactions.count).to eq(2)
        expect(Budget::Import.exists?(import.id)).to be(true)
      end

      it "counts 24 hours as time, not calendar days, across a change of clocks" do
        # Clocks go back at 2:00 on November 1, 2026, so a day later is 25 hours on.
        import = import_of(file, created_at: Time.zone.local(2026, 10, 31, 12))

        travel_to(import.created_at + 24.hours + 1.minute) { expect(import.undo_refusal).to be_present }
        travel_to(import.created_at + 24.hours) { expect(import.undo_refusal).to be_nil }
      end
    end

    describe "only the Account's latest Import" do
      it "is refused for one that has a newer Import after it, which says to undo that one first" do
        older = import_of("2026-08-01,Rent,-1500.00\n", created_at: 2.hours.ago)
        import_of(file, created_at: 1.hour.ago)

        expect { older.undo }.to raise_error(Budget::Import::Refused, "This Import can't be undone while a newer Import is in this account. Undo that one first.")

        expect(older.bank_transactions.count).to eq(1)
      end

      it "says the 24 hours are up first, for one that's both too old and not the latest, since waiting won't help" do
        older = import_of("2026-08-01,Rent,-1500.00\n", created_at: 3.days.ago)
        import_of(file, created_at: 1.hour.ago)

        expect(older.undo_refusal).to eq("This Import ran more than 24 hours ago, so it can't be undone.")
      end

      it "lets the one before be undone once the latest has been, if it ran within 24 hours" do
        older = import_of("2026-08-01,Rent,-1500.00\n", created_at: 5.hours.ago)
        newer = import_of(file, created_at: 1.hour.ago)

        newer.undo
        expect(older.reload.undo_refusal).to be_nil

        expect { older.undo }.to change(Budget::Import, :count).by(-1)
        expect(account.bank_transactions).to be_empty
      end

      it "doesn't let the one before be undone once the latest has been, if it's too old" do
        older = import_of("2026-08-01,Rent,-1500.00\n", created_at: 3.days.ago)
        newer = import_of(file, created_at: 1.hour.ago)

        newer.undo

        expect(older.reload.undo_refusal).to eq("This Import ran more than 24 hours ago, so it can't be undone.")
      end

      it "is judged by the Account's own Imports, not another Account's" do
        import = import_of(file, created_at: 2.hours.ago)
        create(:budget_import, created_at: 1.hour.ago) # Another Account's, which is newer.

        expect(import.undo_refusal).to be_nil
      end

      it "is judged by when they ran, and by the order they were made in at the same moment" do
        moment = Time.zone.local(2026, 9, 15, 10)
        first = import_of("2026-08-01,Rent,-1500.00\n", created_at: moment)
        second = import_of(file, created_at: moment)

        travel_to(moment + 1.minute) do
          expect(first.undo_refusal).to be_present
          expect(second.undo_refusal).to be_nil
        end
      end

      it "is judged when it's undone, after the Account is locked, since another Import may have landed since it was looked at" do
        import = import_of(file, created_at: 2.hours.ago)
        stale = Budget::Import.find(import.id) # What a page looked at.
        import_of("2026-09-03,Hydro,-65.50\n") # Lands afterwards.

        expect { stale.undo }.to raise_error(Budget::Import::Refused, /newer Import/)
      end
    end

    it "brings a file's rows back when it's imported again after being undone, since undone rows no longer count as there" do
      import = import_of(file)
      import.undo

      again = import_of(file)

      expect(again).to have_attributes(duplicates_skipped: 0)
      expect(again.bank_transactions.count).to eq(2)
      expect(account.bank_transactions.pluck(:occurrence)).to all(eq(1))
    end

    it "leaves the CSV format and the Account alone" do
      import = import_of(file)

      import.undo

      expect(Budget::CsvFormat.exists?(csv_format.id)).to be(true)
      expect(Budget::Account.exists?(account.id)).to be(true)
    end

    it "is an Import of nothing but rows of 0 too, which has no bank transactions to delete" do
      import = import_of("2026-09-02,Interest,0.00\n")

      expect { import.undo }.to change(Budget::Import, :count).by(-1).and not_change(Budget::BankTransaction, :count)
    end
  end
end
