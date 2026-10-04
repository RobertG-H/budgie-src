require "rails_helper"

# Reads a file into dates, descriptions and signed amounts, positive for money in (ADR 0009), or refuses it naming the
# first row that can't be read. The builder's preview and every Import use it, so a file can't preview one way and import
# another.
RSpec.describe Budget::CsvFormat::Reader do
  # The one bank's transactions in all three amount styles, as the sample files lay them out: a header row, five rows
  # and a sixth of 0.
  let(:expected_rows) do
    [ [ Date.new(2026, 9, 1), "Paycheck", BigDecimal("2800.00") ],
      [ Date.new(2026, 9, 2), "Loblaws", BigDecimal("-82.45") ],
      [ Date.new(2026, 9, 3), "Hydro", BigDecimal("-65.50") ],
      [ Date.new(2026, 9, 5), "Coffee shop", BigDecimal("-4.25") ],
      [ Date.new(2026, 9, 9), "Hydro rebate", BigDecimal("12.25") ] ]
  end

  def sample(name)
    Rails.root.join("spec/fixtures/files", name).open
  end

  def read(format, file)
    format.read(file)
  end

  def as_triples(reading)
    reading.rows.map { |row| [ row.date, row.description, row.amount ] }
  end

  describe "the amount styles" do
    it "reads one signed column, keeping its sign" do
      format = build(:budget_csv_format, rows_to_skip: 1)

      reading = read(format, sample("signed-sample.csv"))

      expect(reading.refusal).to be_nil
      expect(as_triples(reading)).to eq(expected_rows)
    end

    it "reads separate money in and money out columns, making money out negative" do
      format = build(:budget_csv_format, :in_and_out, rows_to_skip: 1)

      reading = read(format, sample("in-and-out-sample.csv"))

      expect(reading.refusal).to be_nil
      expect(as_triples(reading)).to eq(expected_rows)
    end

    it "reads an unsigned column with a direction, making money in the direction that means it and the rest money out" do
      format = build(:budget_csv_format, :direction, rows_to_skip: 1)

      reading = read(format, sample("direction-sample.csv"))

      expect(reading.refusal).to be_nil
      expect(as_triples(reading)).to eq(expected_rows)
    end

    it "reads the same bank transactions to the same signed amounts in all three styles" do
      signed = read(build(:budget_csv_format, rows_to_skip: 1), sample("signed-sample.csv"))
      in_and_out = read(build(:budget_csv_format, :in_and_out, rows_to_skip: 1), sample("in-and-out-sample.csv"))
      direction = read(build(:budget_csv_format, :direction, rows_to_skip: 1), sample("direction-sample.csv"))

      expect(as_triples(in_and_out)).to eq(as_triples(signed))
      expect(as_triples(direction)).to eq(as_triples(signed))
    end

    it "matches the direction that means money in without regard to case or surrounding space" do
      format = build(:budget_csv_format, :direction, money_in_value: "credit")

      reading = read(format, "2026-09-01,Paycheck,10.00, CREDIT \n2026-09-02,Loblaws,5.00,Debit\n")

      expect(reading.rows.map(&:amount)).to eq([ BigDecimal("10"), BigDecimal("-5") ])
    end

    it "knows which line each row was on" do
      format = build(:budget_csv_format, rows_to_skip: 1)

      reading = read(format, sample("signed-sample.csv"))

      expect(reading.rows.map(&:line)).to eq([ 2, 3, 4, 5, 6 ])
    end
  end

  describe "invert sign" do
    it "flips the sign of every amount, in every style" do
      [ [ :signed, "signed-sample.csv" ], [ :in_and_out, "in-and-out-sample.csv" ], [ :direction, "direction-sample.csv" ] ].each do |style, file|
        format = style == :signed ? build(:budget_csv_format, rows_to_skip: 1, invert_sign: true) : build(:budget_csv_format, style, rows_to_skip: 1, invert_sign: true)

        reading = read(format, sample(file))

        expect(reading.rows.map(&:amount)).to eq(expected_rows.map { |_, _, amount| -amount })
      end
    end
  end

  describe "dates" do
    {
      "YYYY-MM-DD" => "2026-03-04",
      "MM/DD/YYYY" => "03/04/2026",
      "DD/MM/YYYY" => "04/03/2026",
      "YYYYMMDD" => "20260304"
    }.each do |date_format, text|
      it "reads #{date_format}" do
        format = build(:budget_csv_format, date_format: date_format)

        reading = read(format, "#{text},Paycheck,10.00\n")

        expect(reading.rows.sole.date).to eq(Date.new(2026, 3, 4))
      end
    end

    it "reads 03/04/2026 as March 4 with MM/DD/YYYY, and as April 3 with DD/MM/YYYY" do
      us = read(build(:budget_csv_format, date_format: "MM/DD/YYYY"), "03/04/2026,Paycheck,10.00\n")
      day_first = read(build(:budget_csv_format, date_format: "DD/MM/YYYY"), "03/04/2026,Paycheck,10.00\n")

      expect(us.rows.sole.date).to eq(Date.new(2026, 3, 4))
      expect(day_first.rows.sole.date).to eq(Date.new(2026, 4, 3))
    end

    it "reads a month and a day without their leading zeros in the slash formats" do
      format = build(:budget_csv_format, date_format: "MM/DD/YYYY")

      expect(read(format, "3/4/2026,Paycheck,10.00\n").rows.sole.date).to eq(Date.new(2026, 3, 4))
    end

    it "reads a date with space around it" do
      expect(read(build(:budget_csv_format), " 2026-03-04 ,Paycheck,10.00\n").rows.sole.date).to eq(Date.new(2026, 3, 4))
    end
  end

  describe "the file" do
    let(:format) { build(:budget_csv_format) }

    it "has any BOM stripped, so it doesn't spoil the first cell" do
      reading = read(format, "\uFEFF2026-09-01,Paycheck,10.00\n")

      expect(reading.refusal).to be_nil
      expect(reading.rows.sole.date).to eq(Date.new(2026, 9, 1))
    end

    it "may have Windows line endings, and no line ending after its last row" do
      reading = read(format, "2026-09-01,Paycheck,10.00\r\n2026-09-02,Loblaws,-5.00")

      expect(reading.rows.map(&:description)).to eq([ "Paycheck", "Loblaws" ])
      expect(reading.rows.map(&:line)).to eq([ 1, 2 ])
    end

    it "must be UTF-8" do
      reading = read(format, "2026-09-01,Caf\xE9,-5.00\n".b)

      expect(reading.rows).to be_empty
      expect(reading.refusal).to have_attributes(line: nil, message: "The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again.")
    end

    it "reads accents and other characters in UTF-8" do
      reading = read(format, "2026-09-01,Café Crème – 日本,-5.00\n")

      expect(reading.rows.sole.description).to eq("Café Crème – 日本")
    end

    it "can be 2 MB, and no more" do
      # One row with a long description, so that the file is exactly as big as it's given.
      file_of = ->(bytes) { "2026-09-01,#{"x" * (bytes - "2026-09-01,,-5.00\n".bytesize)},-5.00\n" }

      expect(read(format, file_of.call(2.megabytes)).refusal).to be_nil
      expect(read(format, file_of.call(2.megabytes + 1)).refusal).to have_attributes(line: nil, message: "The file is over 2 MB.")
    end

    it "can have 5,000 data rows, and no more" do
      row = "2026-09-01,Coffee shop,-1.00\n"

      expect(read(format, row * 5000).rows.size).to eq(5000)
      expect(read(format, row * 5001).refusal).to have_attributes(line: nil, message: "The file has more than 5,000 rows.")
    end

    it "doesn't count the rows it skips towards the 5,000" do
      format = build(:budget_csv_format, rows_to_skip: 3)

      reading = read(format, "preamble\nmore,preamble\nDate,Description,Amount\n" + "2026-09-01,Coffee shop,-1.00\n" * 5000)

      expect(reading.rows.size).to eq(5000)
    end

    it "skips blank lines, and rows with nothing in them" do
      reading = read(format, "\n2026-09-01,Paycheck,10.00\n\n,,\n2026-09-02,Loblaws,-5.00\n\n")

      expect(reading.refusal).to be_nil
      expect(reading.rows.map(&:line)).to eq([ 2, 5 ])
    end

    it "is refused when there are no rows to read, such as an empty file, or one that skips them all" do
      [ "", "\n\n", "Date,Description,Amount\n" ].each do |text|
        reading = read(build(:budget_csv_format, rows_to_skip: text.include?("Date") ? 1 : 0), text)

        expect(reading.refusal).to have_attributes(line: nil, message: "There are no rows to read after the rows to skip.")
      end
    end

    it "reads from a file or from its text" do
      expect(read(format, StringIO.new("2026-09-01,Paycheck,10.00\n")).rows.size).to eq(1)
      expect(read(format, "2026-09-01,Paycheck,10.00\n").rows.size).to eq(1)
    end
  end

  describe "a row that can't be read" do
    let(:format) { build(:budget_csv_format) }

    # What reading the text refuses, as the message that names the row.
    def refusal_of(text, format = self.format)
      reading = read(format, text)

      expect(reading.rows).to be_empty
      reading.refusal&.message
    end

    it "refuses the file, naming the first bad row, and creates no rows from the good ones before it" do
      reading = read(format, "2026-09-01,Paycheck,10.00\n2026-09-02,Loblaws\n2026-13-45,Hydro,-5.00\n")

      expect(reading.rows).to be_empty
      expect(reading.zero_rows).to eq(0)
      expect(reading.refusal).to have_attributes(line: 2, reason: "has 2 columns, and this CSV format expects 3.")
    end

    it "names the line in the file, counting the rows it skips, blank lines and rows with line breaks in them" do
      format = build(:budget_csv_format, rows_to_skip: 2)
      text = "Account: Chequing\nDate,Description,Amount\n\n2026-09-01,\"Pay\ncheck\",10.00\n2026-09-02,Loblaws,abc\n"

      expect(refusal_of(text, format)).to eq("Line 6: the amount \"abc\" isn't a number.")
    end

    it "says a row has the wrong number of columns, too few or too many" do
      expect(refusal_of("2026-09-01,Paycheck\n")).to eq("Line 1: has 2 columns, and this CSV format expects 3.")
      expect(refusal_of("2026-09-01,Paycheck,10.00,extra\n")).to eq("Line 1: has 4 columns, and this CSV format expects 3.")
    end

    it "says when a date can't be read in the chosen format" do
      expect(refusal_of("13/45/2026,Paycheck,10.00\n", build(:budget_csv_format, date_format: "MM/DD/YYYY")))
        .to eq("Line 1: the date \"13/45/2026\" isn't a date in the MM/DD/YYYY format.")
      expect(refusal_of("2026-02-30,Paycheck,10.00\n")).to eq("Line 1: the date \"2026-02-30\" isn't a date in the YYYY-MM-DD format.")
      expect(refusal_of("yesterday,Paycheck,10.00\n")).to eq("Line 1: the date \"yesterday\" isn't a date in the YYYY-MM-DD format.")
      expect(refusal_of(",Paycheck,10.00\n")).to eq("Line 1: the date is blank.")
      expect(refusal_of("2026-09-01,Paycheck,10.00\n04/09/2026,Hydro,5.00\n")).to eq("Line 2: the date \"04/09/2026\" isn't a date in the YYYY-MM-DD format.")
    end

    describe "a date that can't be right" do
      before { travel_to Time.utc(2026, 10, 15, 16) } # Still October 15 in Eastern time.

      it "can be tomorrow, and no later" do
        expect(read(format, "2026-10-16,Paycheck,10.00\n").refusal).to be_nil
        expect(refusal_of("2026-10-17,Paycheck,10.00\n")).to eq("Line 1: the date 2026-10-17 is more than a day after today.")
      end

      it "is judged by today in Eastern time, which isn't UTC's" do
        travel_to Time.utc(2026, 10, 16, 2) # Still October 15 in Eastern time, though October 16 in UTC.

        expect(read(format, "2026-10-16,Paycheck,10.00\n").refusal).to be_nil
        expect(refusal_of("2026-10-17,Paycheck,10.00\n")).to eq("Line 1: the date 2026-10-17 is more than a day after today.")
      end

      it "can be in 1990, and no earlier" do
        expect(read(format, "1990-01-01,Paycheck,10.00\n").refusal).to be_nil
        expect(refusal_of("1989-12-31,Paycheck,10.00\n")).to eq("Line 1: the date 1989-12-31 is before 1990.")
      end
    end

    it "reads a row the bank gave no description as No description, whichever of its columns it's read from, and doesn't refuse it" do
      expect(read(format, "2026-09-01,,10.00\n")).to have_attributes(refusal: nil, rows: [ have_attributes(line: 1, description: "No description", amount: 10) ])
      expect(read(format, "2026-09-01,   ,10.00\n").rows.map(&:description)).to eq([ "No description" ])

      two_columns = build(:budget_csv_format, column_count: 4, description_columns: [ 2, 3 ], amount_column: 4)
      expect(read(two_columns, "2026-09-01,,,10.00\n").rows.map(&:description)).to eq([ "No description" ])
    end

    it "keeps the description a row has, and only stands in for one that's empty, so a payment with none sits beside the rest of the file" do
      reading = read(format, "2026-09-01,Paycheck,2800.00\n2026-09-02,,-250.00\n2026-09-03,Loblaws,-82.45\n")

      expect(reading.rows.map(&:description)).to eq([ "Paycheck", "No description", "Loblaws" ])
      expect(reading.rows.map(&:amount)).to eq([ 2800, -250, BigDecimal("-82.45") ])
    end

    it "joins the description columns with a space, leaving out a blank one" do
      format = build(:budget_csv_format, column_count: 4, description_columns: [ 3, 2 ], amount_column: 4)

      reading = read(format, "2026-09-01,Visa,Loblaws, -5.00\n2026-09-02,,Hydro,-6.00\n")

      expect(reading.rows.map(&:description)).to eq([ "Loblaws Visa", "Hydro" ])
    end

    describe "an amount" do
      it "says when it isn't a number" do
        [ "abc", "12.3.4", "1 000", "--5", "5-", "1,23", "12,50" ].each do |amount|
          expect(refusal_of("2026-09-01,Paycheck,\"#{amount}\"\n")).to eq("Line 1: the amount \"#{amount}\" isn't a number.")
        end
      end

      it "says when it's blank" do
        expect(refusal_of("2026-09-01,Paycheck,\n")).to eq("Line 1: the amount is blank.")
      end

      it "refuses more than 2 decimal places, which are never rounded" do
        expect(refusal_of("2026-09-01,Paycheck,10.005\n")).to eq("Line 1: the amount \"10.005\" has more than 2 decimal places.")
        expect(refusal_of("2026-09-01,Paycheck,-0.001\n")).to eq("Line 1: the amount \"-0.001\" has more than 2 decimal places.")
      end

      it "allows trailing zeros beyond 2 decimal places, as the core's money rule does" do
        expect(read(format, "2026-09-01,Paycheck,10.500\n").rows.sole.amount).to eq(BigDecimal("10.5"))
      end

      it "says when it's too large to keep" do
        expect(read(format, "2026-09-01,Paycheck,9999999999999.99\n").refusal).to be_nil
        expect(refusal_of("2026-09-01,Paycheck,10000000000000\n")).to eq("Line 1: the amount \"10000000000000\" is too large.")
      end

      it "may have a sign, a currency symbol and thousands separators" do
        amounts = [ "+5.00", "-5.00", "$5.00", "-$5.00", "€5", "£1,234.56", "-1,234,567.89", "1,000", ".50", "-.5", " 7 " ]
        reading = read(format, amounts.map { |amount| "2026-09-01,Paycheck,\"#{amount}\"\n" }.join)

        expect(reading.refusal).to be_nil
        expect(reading.rows.map(&:amount).map(&:to_s)).to eq(%w[ 5.0 -5.0 5.0 -5.0 5.0 1234.56 -1234567.89 1000.0 0.5 -0.5 7.0 ])
      end

      it "is refused with the same words in the other amount styles, naming the amount's own column" do
        expect(refusal_of("2026-09-01,Paycheck,abc,\n", build(:budget_csv_format, :in_and_out))).to eq("Line 1: the amount \"abc\" isn't a number.")
        expect(refusal_of("2026-09-01,Paycheck,,1.005\n", build(:budget_csv_format, :in_and_out))).to eq("Line 1: the amount \"1.005\" has more than 2 decimal places.")
        expect(refusal_of("2026-09-01,Paycheck,abc,Credit\n", build(:budget_csv_format, :direction))).to eq("Line 1: the amount \"abc\" isn't a number.")
      end
    end

    describe "separate money in and money out columns" do
      let(:format) { build(:budget_csv_format, :in_and_out) }

      it "refuses a row with both filled" do
        expect(refusal_of("2026-09-01,Paycheck,5.00,10.00\n")).to eq("Line 1: has both a money in amount and a money out amount.")
      end

      it "refuses a row with neither, since it has no amount at all" do
        expect(refusal_of("2026-09-01,Paycheck,,\n")).to eq("Line 1: has neither a money in amount nor a money out amount.")
      end

      it "reads the size of an amount whatever its sign, since which column it's in says which way the money went" do
        reading = read(format, "2026-09-01,Hydro,-5.00,\n2026-09-02,Refund,,-6.00\n")

        expect(reading.rows.map(&:amount)).to eq([ BigDecimal("-5"), BigDecimal("6") ])
      end
    end

    describe "a direction" do
      let(:format) { build(:budget_csv_format, :direction) }

      it "refuses a row with no direction, since the money could be going either way" do
        expect(refusal_of("2026-09-01,Paycheck,10.00,\n")).to eq("Line 1: the direction is blank.")
      end

      it "reads any other direction as money out" do
        reading = read(format, "2026-09-01,Hydro,5.00,Debit\n2026-09-02,Odd,6.00,Hold\n")

        expect(reading.rows.map(&:amount)).to eq([ BigDecimal("-5"), BigDecimal("-6") ])
      end
    end

    it "refuses a file that isn't valid CSV, naming where" do
      expect(refusal_of("2026-09-01,Paycheck,10.00\n2026-09-02,\"Loblaws,-5.00\n"))
        .to match(/\ALine 2: isn't valid CSV \(Unclosed quoted field\)\.\z/)
    end

    it "doesn't print more than a little of a long value" do
      message = refusal_of("2026-09-01,Paycheck,#{"9" * 100}x\n")

      expect(message.length).to be < 120
      expect(message).to include("...")
    end
  end

  describe "rows of 0" do
    it "are skipped, and counted, instead of being refused" do
      reading = read(build(:budget_csv_format, rows_to_skip: 1), sample("signed-sample.csv"))

      expect(reading.refusal).to be_nil
      expect(reading.zero_rows).to eq(1)
      expect(reading.rows.map(&:description)).not_to include("Savings interest")
    end

    it "are skipped whatever the amount style, and with an inverted sign, so -0 isn't kept either" do
      [ [ build(:budget_csv_format, :in_and_out, invert_sign: true), "2026-09-01,Interest,,0.00\n" ],
        [ build(:budget_csv_format, :direction), "2026-09-01,Interest,0,Credit\n" ],
        [ build(:budget_csv_format, invert_sign: true), "2026-09-01,Interest,-0.00\n" ] ].each do |format, text|
        reading = read(format, text)

        expect(reading.rows).to be_empty
        expect(reading.zero_rows).to eq(1)
      end
    end

    it "are still refused when anything else about the row is wrong" do
      expect(read(build(:budget_csv_format), "2026-09-01,Interest,nope\n").refusal).to have_attributes(line: 1)
      expect(read(build(:budget_csv_format), "nope,Interest,0.00\n").refusal).to have_attributes(line: 1)
    end

    it "alone are a file with nothing to keep, but not one with no rows" do
      reading = read(build(:budget_csv_format), "2026-09-01,Interest,0.00\n")

      expect(reading.refusal).to be_nil
      expect(reading.rows).to be_empty
      expect(reading.zero_rows).to eq(1)
    end
  end

  # A refusal that's about the file itself says so, which is what tells one that every CSV format would give from one that's only this
  # format's, such as the wrong number of columns. It's how a file nothing reads is explained without listing every format's.
  describe "which refusals are about the file itself" do
    let(:format) { build(:budget_csv_format) }

    def refusal_for(text, format = self.format)
      read(format, text).refusal
    end

    it "are a file that isn't UTF-8, one that's over 2 MB, one with more than 5,000 rows, and one that isn't CSV" do
      expect(refusal_for("2026-09-01,Caf\xE9,-5.00\n".b)).to be_about_the_file
      expect(refusal_for("2026-09-01,#{"x" * 2.megabytes},-5.00\n")).to be_about_the_file
      expect(refusal_for("2026-09-01,Coffee shop,-1.00\n" * 5001)).to be_about_the_file
      expect(refusal_for("2026-09-01,\"Loblaws,-5.00\n")).to be_about_the_file
    end

    it "are a file with nothing in it, whatever the CSV format skips, including one of nothing but blank lines" do
      [ "", "\n\n", ",,\n" ].each do |text|
        expect(refusal_for(text, build(:budget_csv_format, rows_to_skip: 0))).to be_about_the_file
        expect(refusal_for(text, build(:budget_csv_format, rows_to_skip: 5))).to be_about_the_file
      end
    end

    it "aren't a file the format skips all of, which another format might read" do
      refusal = refusal_for("Date,Description,Amount\n", build(:budget_csv_format, rows_to_skip: 1))

      expect(refusal.message).to eq("There are no rows to read after the rows to skip.")
      expect(refusal).not_to be_about_the_file
    end

    it "aren't a row this format can't read: the wrong number of columns, a date, an amount" do
      expect(refusal_for("2026-09-01,Paycheck\n")).not_to be_about_the_file
      expect(refusal_for("yesterday,Paycheck,10.00\n")).not_to be_about_the_file
      expect(refusal_for("2026-09-01,Paycheck,lots\n")).not_to be_about_the_file
    end

    it "keep their message, and a line only when a row is to blame, as before" do
      expect(refusal_for("2026-09-01,Caf\xE9,-5.00\n".b)).to have_attributes(line: nil, message: "The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again.")
      expect(refusal_for("2026-09-01,Paycheck\n")).to have_attributes(line: 1, message: "Line 1: has 2 columns, and this CSV format expects 3.")
    end

    it "are the same read from a Source that was made once, as a guess reads one file with every format" do
      source = Budget::CsvFormat::Source.new("2026-09-01,Paycheck,10.00\n")

      expect(read(format, source).rows.size).to eq(1)
      expect(read(build(:budget_csv_format, column_count: 4, description_columns: [ 2 ], amount_column: 3), source).refusal).not_to be_about_the_file
    end
  end
end
