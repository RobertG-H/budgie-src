require "rails_helper"

RSpec.describe Budget::CsvFormat, type: :model do
  subject { build(:budget_csv_format) }

  it { is_expected.to belong_to(:budget) }
  it { is_expected.to have_many(:imports).class_name("Budget::Import").dependent(:restrict_with_error) }

  it "uses the budget_csv_formats table, and is named without the Budget prefix in routes and params" do
    expect(Budget::CsvFormat.table_name).to eq("budget_csv_formats")
    expect(Budget::CsvFormat.model_name).to have_attributes(route_key: "csv_formats", param_key: "csv_format")
  end

  it "is valid as built by the factory, in each amount style" do
    expect(build(:budget_csv_format)).to be_valid
    expect(build(:budget_csv_format, :in_and_out)).to be_valid
    expect(build(:budget_csv_format, :direction)).to be_valid
  end

  it { is_expected.to have_many(:default_for_accounts).class_name("Budget::Account").with_foreign_key(:default_csv_format_id).dependent(:nullify) }

  describe "deleting one that's some Accounts' default" do
    let(:budget) { create(:budget) }
    let(:csv_format) { create(:budget_csv_format, budget: budget) }

    it "works when it's only a default, and clears the default of each Account that had it" do
      first = create(:budget_account, budget: budget, default_csv_format: csv_format)
      second = create(:budget_account, budget: budget, default_csv_format: csv_format)
      other = create(:budget_account, budget: budget, default_csv_format: create(:budget_csv_format, budget: budget))

      expect(csv_format.destroy).to be_truthy

      expect(Budget::CsvFormat.exists?(csv_format.id)).to be(false)
      expect([ first, second ].map { |account| account.reload.default_csv_format }).to eq([ nil, nil ])
      expect(other.reload.default_csv_format).not_to be_nil
    end

    it "is still refused when an Import used it, and then clears nothing" do
      account = create(:budget_account, budget: budget, default_csv_format: csv_format)
      create(:budget_import, account: account, csv_format: csv_format)

      expect(csv_format.destroy).to be(false)

      expect(csv_format.errors.full_messages).to eq([ "This CSV format can't be deleted because an Import used it." ])
      expect(account.reload.default_csv_format).to eq(csv_format)
    end

    it "lists the Accounts it's the default for, for the question before deleting" do
      create(:budget_account, budget: budget, default_csv_format: csv_format)
      create(:budget_account, budget: budget)

      expect(csv_format.default_for_accounts.count).to eq(1)
    end
  end

  describe "name" do
    it { is_expected.to validate_presence_of(:name) }

    it "squishes surrounding and repeated whitespace" do
      expect(Budget::CsvFormat.new(name: "  My \n bank  ").name).to eq("My bank")
    end

    it "can't be only whitespace" do
      format = build(:budget_csv_format, name: " \n ")

      expect(format).not_to be_valid
      expect(format.errors.full_messages).to eq([ "Name can't be blank" ])
    end

    it "is unique in a budget, whatever its case" do
      budget = create(:budget)
      create(:budget_csv_format, budget: budget, name: "My bank")

      format = build(:budget_csv_format, budget: budget, name: "my BANK")

      expect(format).not_to be_valid
      expect(format.errors.full_messages).to eq([ "Name has already been taken" ])
    end

    it "may be the same as another budget's" do
      create(:budget_csv_format, name: "My bank")

      expect(build(:budget_csv_format, name: "My bank")).to be_valid
    end
  end

  describe "rows to skip" do
    it "may be 0, or any whole number of rows" do
      expect(build(:budget_csv_format, rows_to_skip: 0)).to be_valid
      expect(build(:budget_csv_format, rows_to_skip: 12)).to be_valid
    end

    it "starts at 0" do
      expect(Budget::CsvFormat.new.rows_to_skip).to eq(0)
    end

    it "can't be negative, or part of a row, or silly" do
      [ -1, "1.5", "many", 1001 ].each do |rows|
        format = build(:budget_csv_format, rows_to_skip: rows)

        expect(format).not_to be_valid
        expect(format.errors[:rows_to_skip]).to be_present
      end
    end
  end

  describe "column count, which is the sample's" do
    it "must be known, so a format can't be saved without a sample to read it from" do
      format = build(:budget_csv_format, column_count: nil)

      expect(format).not_to be_valid
      expect(format.errors.full_messages_for(:column_count)).to eq([ "Sample file must be chosen, so the columns can be read from it" ])
    end

    it "is at least 1" do
      format = build(:budget_csv_format, column_count: 0)

      expect(format).not_to be_valid
      expect(format.errors[:column_count]).to be_present
    end

    it "can't be more than a bank's file could have" do
      expect(build(:budget_csv_format, column_count: 100)).to be_valid
      expect(build(:budget_csv_format, column_count: 101)).not_to be_valid
    end
  end

  describe "date" do
    it "is read from a column within the sample's" do
      expect(build(:budget_csv_format, date_column: 3)).to be_valid

      [ nil, 0, 4 ].each do |column|
        format = build(:budget_csv_format, date_column: column)

        expect(format).not_to be_valid
        expect(format.errors[:date_column]).to be_present
      end
    end

    it "says which columns there are" do
      format = build(:budget_csv_format, date_column: 4)

      format.valid?

      expect(format.errors.full_messages_for(:date_column)).to eq([ "Date column must be one of the sample's columns, 1 to 3" ])
    end

    it "is in one of the four formats" do
      [ "YYYY-MM-DD", "MM/DD/YYYY", "DD/MM/YYYY", "YYYYMMDD" ].each do |date_format|
        expect(build(:budget_csv_format, date_format: date_format)).to be_valid
      end

      [ nil, "", "DD-MM-YYYY", "yyyy-mm-dd" ].each do |date_format|
        format = build(:budget_csv_format, date_format: date_format)

        expect(format).not_to be_valid
        expect(format.errors[:date_format]).to be_present
      end
    end
  end

  describe "description columns" do
    it "are one or more columns within the sample's" do
      expect(build(:budget_csv_format, description_columns: [ 2 ])).to be_valid
      expect(build(:budget_csv_format, description_columns: [ 2, 1 ])).to be_valid

      [ nil, [], [ 0 ], [ 2, 4 ] ].each do |columns|
        format = build(:budget_csv_format, description_columns: columns)

        expect(format).not_to be_valid
        expect(format.errors[:description_columns]).to be_present
      end
    end

    it "can't repeat a column" do
      format = build(:budget_csv_format, description_columns: [ 2, 2 ])

      expect(format).not_to be_valid
      expect(format.errors.full_messages_for(:description_columns)).to eq([ "Description columns can't repeat a column" ])
    end

    it "can be given as the numbers a person types, separated by commas or spaces" do
      expect(Budget::CsvFormat.new(description_columns: "2, 4").description_columns).to eq([ 2, 4 ])
      expect(Budget::CsvFormat.new(description_columns: " 3 ").description_columns).to eq([ 3 ])
      expect(Budget::CsvFormat.new(description_columns: "1 2,3").description_columns).to eq([ 1, 2, 3 ])
      expect(Budget::CsvFormat.new(description_columns: "").description_columns).to eq([])
    end

    it "is refused when what's typed isn't numbers, instead of being read as some" do
      format = build(:budget_csv_format, description_columns: "2, payee")

      expect(format).not_to be_valid
      expect(format.errors[:description_columns]).to be_present
    end
  end

  describe "amount style" do
    it "is one of the three" do
      [ nil, "", "both" ].each do |style|
        format = build(:budget_csv_format, amount_style: style)

        expect(format).not_to be_valid
        expect(format.errors[:amount_style]).to be_present
      end
    end

    describe "signed" do
      it "needs its amount column, within the sample's" do
        [ nil, 0, 4 ].each do |column|
          format = build(:budget_csv_format, amount_column: column)

          expect(format).not_to be_valid
          expect(format.errors[:amount_column]).to be_present
        end
      end

      it "leaves the other styles' columns unset, whatever was sent for them" do
        format = create(:budget_csv_format, money_in_column: 1, money_out_column: 2, direction_column: 3, money_in_value: "Credit")

        expect(format).to have_attributes(money_in_column: nil, money_out_column: nil, direction_column: nil, money_in_value: nil)
      end
    end

    describe "money in and money out in separate columns" do
      subject { build(:budget_csv_format, :in_and_out) }

      it "needs both columns, within the sample's" do
        [ :money_in_column, :money_out_column ].each do |attribute|
          [ nil, 0, 5 ].each do |column|
            format = build(:budget_csv_format, :in_and_out, attribute => column)

            expect(format).not_to be_valid
            expect(format.errors[attribute]).to be_present
          end
        end
      end

      it "needs them to be different columns" do
        format = build(:budget_csv_format, :in_and_out, money_in_column: 3, money_out_column: 3)

        expect(format).not_to be_valid
        expect(format.errors.full_messages_for(:money_out_column)).to eq([ "Money out column can't be the same column as money in" ])
      end

      it "leaves the other styles' columns unset, whatever was sent for them" do
        format = create(:budget_csv_format, :in_and_out, amount_column: 1, direction_column: 2, money_in_value: "Credit")

        expect(format).to have_attributes(amount_column: nil, direction_column: nil, money_in_value: nil)
      end
    end

    describe "one unsigned amount and a direction" do
      subject { build(:budget_csv_format, :direction) }

      it "needs its amount column and its direction column, within the sample's" do
        [ :amount_column, :direction_column ].each do |attribute|
          [ nil, 0, 5 ].each do |column|
            format = build(:budget_csv_format, :direction, attribute => column)

            expect(format).not_to be_valid
            expect(format.errors[attribute]).to be_present
          end
        end
      end

      it "needs them to be different columns" do
        format = build(:budget_csv_format, :direction, amount_column: 3, direction_column: 3)

        expect(format).not_to be_valid
        expect(format.errors.full_messages_for(:direction_column)).to eq([ "Direction column can't be the same column as the amount" ])
      end

      it "needs the direction that means money in" do
        [ nil, "", "  " ].each do |value|
          format = build(:budget_csv_format, :direction, money_in_value: value)

          expect(format).not_to be_valid
          expect(format.errors.full_messages_for(:money_in_value)).to eq([ "Direction for money in can't be blank" ])
        end
      end

      it "trims the direction that means money in" do
        expect(build(:budget_csv_format, :direction, money_in_value: " Credit ").money_in_value).to eq("Credit")
      end

      it "leaves the other styles' columns unset, whatever was sent for them" do
        format = create(:budget_csv_format, :direction, money_in_column: 1, money_out_column: 2)

        expect(format).to have_attributes(money_in_column: nil, money_out_column: nil)
      end
    end
  end

  describe "invert sign" do
    it "starts off, and can't be unknown" do
      expect(Budget::CsvFormat.new.invert_sign).to be(false)
      expect(build(:budget_csv_format, invert_sign: nil)).not_to be_valid
    end
  end

  describe "database constraints" do
    let(:format) { create(:budget_csv_format) }
    let(:in_and_out) { create(:budget_csv_format, :in_and_out) }
    let(:direction) { create(:budget_csv_format, :direction) }

    # Plain SQL, because the model would normalize or reject most of these values before the database saw them. Each
    # runs in a savepoint, because PostgreSQL aborts the transaction at the first violation, which would stop an example
    # from checking a second one.
    def update_format(format, assignments)
      Budget::CsvFormat.transaction(requires_new: true) { Budget::CsvFormat.where(id: format.id).update_all(assignments) }
    end

    it "rejects a blank name" do
      expect { update_format(format, "name = '   '") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_name_not_blank/)
    end

    it "rejects the same name in another case in a budget, and allows it in another budget" do
      create(:budget_csv_format, budget: format.budget, name: "Other")

      expect { update_format(format, "name = 'OTHER'") }.to raise_error(ActiveRecord::RecordNotUnique, /index_budget_csv_formats_on_budget_id_and_lower_name/)
    end

    it "rejects a negative number of rows to skip" do
      expect { update_format(format, "rows_to_skip = -1") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_rows_to_skip_not_negative/)
    end

    it "rejects a column count of 0" do
      expect { update_format(format, "column_count = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_column_count_positive/)
    end

    it "rejects more columns, and more rows to skip, than any bank's file has, as the model does" do
      expect { update_format(format, "column_count = 101") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_column_count_at_most_100/)
      expect { update_format(format, "rows_to_skip = 1001") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_rows_to_skip_at_most_1000/)
    end

    it "rejects a date column outside the columns" do
      expect { update_format(format, "date_column = 4") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_date_column_within_count/)
      expect { update_format(format, "date_column = 0") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_date_column_within_count/)
    end

    it "rejects a date format it doesn't know" do
      expect { update_format(format, "date_format = 'DD-MM-YYYY'") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_date_format_known/)
    end

    it "rejects no description columns, or any outside the columns" do
      expect { update_format(format, "description_columns = '{}'") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_description_columns_within_count/)
      expect { update_format(format, "description_columns = '{2,4}'") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_description_columns_within_count/)
      expect { update_format(format, "description_columns = '{0}'") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_description_columns_within_count/)
    end

    it "rejects an amount style it doesn't know" do
      expect { update_format(format, "amount_style = 'both'") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_amount_style_known/)
    end

    describe "a signed amount" do
      it "needs its column, and in the columns" do
        expect { update_format(format, "amount_column = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_signed_columns/)
        expect { update_format(format, "amount_column = 4") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_signed_columns/)
      end

      it "has none of another style's columns" do
        expect { update_format(format, "money_in_column = 1") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_signed_columns/)
      end

      it "has none of the direction style's" do
        expect { update_format(format, "money_in_value = 'Credit'") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_signed_columns/)
      end
    end

    describe "money in and money out in separate columns" do
      it "needs both columns, and in the columns" do
        expect { update_format(in_and_out, "money_in_column = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_in_and_out_columns/)
        expect { update_format(in_and_out, "money_out_column = 5") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_in_and_out_columns/)
      end

      it "needs them to be different columns" do
        expect { update_format(in_and_out, "money_out_column = money_in_column") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_in_and_out_columns/)
      end

      it "has no other style's columns" do
        expect { update_format(in_and_out, "amount_column = 1") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_in_and_out_columns/)
        expect { update_format(in_and_out, "direction_column = 1") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_in_and_out_columns/)
      end
    end

    describe "one unsigned amount and a direction" do
      it "needs its columns, and in the columns" do
        expect { update_format(direction, "direction_column = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_direction_columns/)
        expect { update_format(direction, "amount_column = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_direction_columns/)
        expect { update_format(direction, "direction_column = 5") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_direction_columns/)
      end

      it "needs them to be different columns" do
        expect { update_format(direction, "direction_column = amount_column") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_direction_columns/)
      end

      it "needs the direction that means money in" do
        expect { update_format(direction, "money_in_value = NULL") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_direction_columns/)
        expect { update_format(direction, "money_in_value = ' '") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_direction_columns/)
      end

      it "has no money in or money out columns" do
        expect { update_format(direction, "money_in_column = 1") }.to raise_error(ActiveRecord::CheckViolation, /budget_csv_formats_direction_columns/)
      end
    end

    # One column per example: PostgreSQL aborts the spec's transaction at the first violation.
    %w[ budget_id name rows_to_skip column_count date_column date_format description_columns amount_style invert_sign ].each do |column|
      it "requires a #{column}" do
        expect { update_format(format, "#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end

    it "keeps a budget with CSV formats from being deleted without them" do
      expect { Budget.where(id: format.budget_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
