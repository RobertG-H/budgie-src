# Reads a bank's CSV file with a CSV format: each row becomes a date, a description and a signed amount, positive for money
# in (ADR 0009), or the first row that can't be read is refused. The builder's preview and every Import use this, so a file
# can't preview one way and import another.
class Budget::CsvFormat::Reader
  # A row as the format reads it, and the line it started on in the file, which is what a refusal names.
  Row = Data.define(:line, :date, :description, :amount)

  # What a file reads to: its rows, and how many of them were of 0, which aren't rows to keep, or the one thing that's
  # wrong with it, in which case there are no rows.
  Reading = Data.define(:rows, :zero_rows, :refusal)

  # What a row the bank gave no description is read as, since everything a bank transaction becomes needs one: a record is filed with a
  # description, and a Filing rule or a Guess goes by it. Some banks leave it empty for some rows, such as a card's payments. The text is
  # one a Filing rule can look for, so a person can ignore them all with one.
  NO_DESCRIPTION = "No description"

  MAX_DATA_ROWS = 5_000
  EARLIEST_DATE = Date.new(1990, 1, 1)

  # A sign, a currency symbol, then digits with commas between each group of three, and decimals.
  AMOUNT_PATTERN = /\A(?<sign>[+-])?[$€£]?(?<whole>\d{1,3}(?:,\d{3})+|\d+)?(?:\.(?<fraction>\d+))?\z/

  DATE_PATTERNS = {
    "YYYY-MM-DD" => [ /\A(\d{4})-(\d{2})-(\d{2})\z/, %i[ year month day ] ],
    "MM/DD/YYYY" => [ %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}, %i[ month day year ] ],
    "DD/MM/YYYY" => [ %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}, %i[ day month year ] ],
    "YYYYMMDD" => [ /\A(\d{4})(\d{2})(\d{2})\z/, %i[ year month day ] ]
  }.freeze

  def initialize(format)
    @format = format
  end

  # `file` is anything that can be read, such as an uploaded file, or the text of one, or a Source already made from one.
  def read(file)
    rows = []
    zero_rows = 0
    source = file.is_a?(Budget::CsvFormat::Source) ? file : Budget::CsvFormat::Source.new(file)

    source.each_row.with_index do |(line, cells), index|
      next if index < @format.rows_to_skip || cells.all?(&:blank?)

      refuse(nil, "The file has more than #{MAX_DATA_ROWS.to_fs(:delimited)} rows.") if rows.size + zero_rows >= MAX_DATA_ROWS

      row = read_row(line, cells)
      row.amount.zero? ? zero_rows += 1 : rows << row
    end

    refuse(nil, "There are no rows to read after the rows to skip.") if rows.empty? && zero_rows.zero?
    Reading.new(rows: rows, zero_rows: zero_rows, refusal: nil)
  rescue Budget::CsvFormat::Refused => refused
    Reading.new(rows: [], zero_rows: 0, refusal: refused.refusal)
  end

  private
    # Stops reading, and says why. Nothing is read from a file that has anything wrong with it.
    def refuse(line, reason)
      raise Budget::CsvFormat::Refused, Budget::CsvFormat::Refusal.new(line: line, reason: reason)
    end

    # A value from the file as a refusal quotes it, which isn't more than a little of it.
    def quote(text)
      "\"#{text.truncate(30)}\""
    end

    def read_row(line, cells)
      unless cells.size == @format.column_count
        refuse(line, "has #{cells.size} #{"column".pluralize(cells.size)}, and this CSV format expects #{@format.column_count}.")
      end

      date = read_date(line, cells[@format.date_column - 1])
      description = read_description(cells)
      Row.new(line: line, date: date, description: description, amount: read_amount(line, cells))
    end

    def read_date(line, cell)
      text = cell.to_s.strip
      refuse(line, "the date is blank.") if text.empty?

      pattern, parts = DATE_PATTERNS.fetch(@format.date_format)
      numbers = text.match(pattern)&.captures&.map(&:to_i)
      date = parts.zip(numbers).to_h if numbers
      refuse(line, "the date #{quote(text)} isn't a date in the #{@format.date_format} format.") unless date && Date.valid_date?(date[:year], date[:month], date[:day])

      date = Date.new(date[:year], date[:month], date[:day])
      refuse(line, "the date #{date.iso8601} is more than a day after today.") if date > Date.current + 1
      refuse(line, "the date #{date.iso8601} is before #{EARLIEST_DATE.year}.") if date < EARLIEST_DATE
      date
    end

    # The description columns joined with a space, leaving out any that are blank, or NO_DESCRIPTION when all of them are.
    def read_description(cells)
      @format.description_columns.map { |column| cells[column - 1].to_s.strip }.compact_blank.join(" ").presence || NO_DESCRIPTION
    end

    def read_amount(line, cells)
      amount = case @format.amount_style
      when "signed"
        parse_amount(line, cells[@format.amount_column - 1])
      when "in_and_out"
        money_in, money_out = cells.values_at(@format.money_in_column - 1, @format.money_out_column - 1).map { |cell| cell.to_s.strip }
        refuse(line, "has both a money in amount and a money out amount.") if money_in.present? && money_out.present?
        refuse(line, "has neither a money in amount nor a money out amount.") if money_in.blank? && money_out.blank?
        money_in.present? ? parse_amount(line, money_in).abs : -parse_amount(line, money_out).abs
      when "direction"
        read_directed_amount(line, cells)
      end

      @format.invert_sign ? -amount : amount
    end

    # An unsigned amount, which is money in when the direction column holds the direction that means it. A row of 0 has no
    # way to go, so what its direction is doesn't matter.
    def read_directed_amount(line, cells)
      amount = parse_amount(line, cells[@format.amount_column - 1]).abs
      return amount if amount.zero?

      direction = cells[@format.direction_column - 1].to_s.strip
      refuse(line, "the direction is blank.") if direction.empty?
      direction.casecmp?(@format.money_in_value) ? amount : -amount
    end

    # A number with a sign, a currency symbol and thousands separators if it has them, and at most 2 decimal places, which
    # are never rounded.
    def parse_amount(line, cell)
      text = cell.to_s.strip
      refuse(line, "the amount is blank.") if text.empty?

      match = AMOUNT_PATTERN.match(text)
      refuse(line, "the amount #{quote(text)} isn't a number.") unless match && (match[:whole] || match[:fraction])

      amount = BigDecimal("#{match[:whole].to_s.delete(",").presence || "0"}.#{match[:fraction] || "0"}")
      refuse(line, "the amount #{quote(text)} has more than 2 decimal places.") if amount.round(2) != amount
      refuse(line, "the amount #{quote(text)} is too large.") if amount >= MoneyValidator::LIMIT

      match[:sign] == "-" ? -amount : amount
    end
end
