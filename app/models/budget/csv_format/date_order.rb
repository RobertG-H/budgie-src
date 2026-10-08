# The order a CSV format reads a date's day, month and year in, which is the one thing about a date a file can't say for
# itself: 03/04/2026 is March 4 month first and April 3 day first. Everything else is read whatever it is: any separator, or
# none for eight digits such as 20261007, a day and a month of one or two digits, a day with "st", "nd", "rd" or "th", a month
# as an English word ("Oct", "Sept.", "October"), a weekday in front, and a time after the date, which is dropped.
#
# A year is four digits, or two when it comes after the day: dates are never before 1990 (EARLIEST_DATE) or after tomorrow,
# so 95 can only be 1995 and 26 only 2026. A year first is always four digits, so 26-10-07 isn't read as one.
#
# A month as a word says which number is the month, so month, day, year and day, month, year read "7 Oct 2026" and "Oct 7,
# 2026" alike: only whether the year comes first matters for those.
class Budget::CsvFormat::DateOrder
  ORDERS = %w[ year_month_day month_day_year day_month_year ].freeze

  LABELS = { "year_month_day" => "Year, month, day", "month_day_year" => "Month, day, year", "day_month_year" => "Day, month, year" }.freeze

  # What each order looks like, for the form, so a person can match it to their file.
  EXAMPLES = { "year_month_day" => "2026-10-07", "month_day_year" => "10/07/2026", "day_month_year" => "07/10/2026" }.freeze

  EARLIEST_DATE = Date.new(1990, 1, 1)

  MONTHS = Date::ABBR_MONTHNAMES.compact.map(&:downcase).zip(1..12).to_h
    .merge(Date::MONTHNAMES.compact.map(&:downcase).zip(1..12).to_h, "sept" => 9).freeze

  WEEKDAYS = (Date::ABBR_DAYNAMES + Date::DAYNAMES).map(&:downcase).push("tues", "thur", "thurs").to_set.freeze

  # A time after the date, from its hours and minutes on, with whatever follows them, such as seconds, AM or a zone. It's after
  # a space, or the T of 2026-10-07T14:30:00Z.
  TIME = /(?:t|\s+)\d{1,2}:\d{2}.*\z/

  # A number, with an ordinal's letters if it's a day, or a word.
  TOKEN = /\d{1,2}(?:st|nd|rd|th)(?![a-z])|\d+|[a-z]+/

  # What may come between the parts of a date.
  SEPARATORS = /\A[\s\-\/.,]*\z/

  # A year first is four digits, and any other part has its usual width, for a date written as digits with nothing between.
  WIDTHS = { "year" => 4, "month" => 2, "day" => 2 }.freeze

  def self.label(order)
    LABELS[order]
  end

  # The only order the dates in `texts` read in, which is how the builder chooses one from a sample. Every one of them has to
  # read as a date from 1990 to tomorrow, so a day over 12 rules out the order with the month there. Nil when no order reads
  # them all, or more than one does and they don't read them the same, such as a file whose days are all 12 or under.
  def self.detect(texts)
    texts = texts.map { |text| text.to_s.strip }.reject(&:empty?)
    return if texts.empty?

    readings = ORDERS.index_with { |order| new(order).read_all(texts) }.compact
    return unless readings.values.uniq.one?

    # Orders that read every date the same differ only in what's written down, so the one that's chosen is the one that looks
    # like the file: month first for "Oct 7, 2026", day first for "7 Oct 2026".
    preferred = MONTHS.key?(texts.first.downcase.scan(TOKEN).find { |token| !WEEKDAYS.include?(token) }) ? "month_day_year" : "day_month_year"
    readings.key?(preferred) ? preferred : readings.keys.first
  end

  def initialize(order)
    @order = order
  end

  # The date `text` is in this order, or nil when it isn't one. Whether it's a date the reader takes, which is from 1990 to
  # tomorrow, is the reader's to say.
  def read(text)
    text = text.to_s.downcase.sub(TIME, "").strip
    return unless ORDERS.include?(@order) && text.gsub(TOKEN, "").match?(SEPARATORS)

    words, numbers = text.scan(TOKEN).partition { |token| token.match?(/\A[a-z]+\z/) }
    words -= WEEKDAYS.to_a
    numbers = numbers.map { |number| number.delete("^0-9") }

    parts = if words.empty? then numeric_parts(numbers)
    elsif words.one? && MONTHS.key?(words.first) then worded_parts(MONTHS.fetch(words.first), numbers)
    end
    date_of(parts) if parts
  end

  # The dates of every one of `texts`, or nil when any of them isn't a date the reader would take.
  def read_all(texts)
    texts.map do |text|
      date = read(text)
      return unless date&.between?(EARLIEST_DATE, Date.current + 1)

      date
    end
  end

  private
    def fields
      @order.split("_")
    end

    def year_first?
      fields.first == "year"
    end

    # Three numbers in this order, or eight digits with nothing between them.
    def numeric_parts(numbers)
      if numbers.size == 3
        fields.zip(numbers).to_h
      elsif numbers.one? && numbers.first.size == 8
        digits = numbers.first.dup
        fields.index_with { |field| digits.slice!(0, WIDTHS.fetch(field)) }
      end
    end

    # A day and a year, with the month a word, which are the other way round only when the year comes first.
    def worded_parts(month, numbers)
      return unless numbers.size == 2

      day, year = year_first? ? numbers.reverse : numbers
      { "year" => year, "month" => month, "day" => day }
    end

    def date_of(parts)
      year, month, day = parts.values_at("year", "month", "day")
      return unless year.size == 4 || (year.size == 2 && !year_first?)
      return unless day.size.between?(1, 2) && (month.is_a?(Integer) || month.size.between?(1, 2))

      year = year.size == 2 ? two_digit_year(year.to_i) : year.to_i
      month = month.to_i
      Date.new(year, month, day.to_i) if Date.valid_date?(year, month, day.to_i)
    end

    # 90 to 99 are the 1990s and the rest are this century, which holds for every date the reader takes until 2090.
    def two_digit_year(year)
      year >= EARLIEST_DATE.year % 100 ? 1900 + year : 2000 + year
    end
end
