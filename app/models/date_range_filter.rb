# A range of dates to filter a list by, from the two dates a date field sends ("2026-10-01"), such as the Records page's and the
# Bank transactions page's. Both ends blank is the current month, so a page that's opened with no filter lists this month. A range
# that can't be used, with one end blank, an end that isn't a date, or From after To, is never an empty page because of a typo: it
# has an `error` that says so, and its dates are the current month instead.
#
# A year has one to six digits, because a date field takes up to 275760, and none is outside 1 to 275760.
class DateRangeFilter
  MIN_YEAR = 1
  MAX_YEAR = 275760
  DATE = /\A(\d{4,6})-(\d{2})-(\d{2})\z/
  ERROR = "Choose a From and a To date, with From first. Showing this month instead.".freeze

  # A range a link can ask for, with the params that spell it.
  Preset = Data.define(:key, :label, :from, :to) do
    def params
      { date_from: DateRangeFilter.spell(from), date_to: DateRangeFilter.spell(to) }
    end
  end

  attr_reader :from, :to, :error

  # `from` and `to` are what came in: strings, or anything at all, such as nil or the array a hand-made query can send.
  def initialize(from:, to:, today: Date.current)
    @today = today
    @from, @to, @error = resolve(from, to)
  end

  # A date as a date field spells it: four digits or more of year, so 1 is "0001" and 275760 is "275760".
  def self.spell(date)
    date.strftime("%Y-%m-%d")
  end

  def valid?
    error.nil?
  end

  def range
    from..to
  end

  # Whether it's the range a page starts on, the current month.
  def default?
    [ from, to ] == [ default_from, default_to ]
  end

  # This month, Last month and Last 3 months (the current month and the two before it), in the order they're offered.
  def presets
    @presets ||= [
      Preset.new(key: :this_month, label: "This month", from: default_from, to: default_to),
      Preset.new(key: :last_month, label: "Last month", from: default_from.prev_month, to: default_from.prev_month.end_of_month),
      Preset.new(key: :last_3_months, label: "Last 3 months", from: default_from.prev_month.prev_month, to: default_to)
    ]
  end

  # The key of the preset this range equals, if it equals one.
  def preset
    presets.find { |candidate| [ candidate.from, candidate.to ] == [ from, to ] }&.key
  end

  # The range as the params that spell it, such as in a link or a hidden field: the dates actually in use.
  def to_params
    { date_from: self.class.spell(from), date_to: self.class.spell(to) }
  end

  private
    attr_reader :today

    def default_from
      today.beginning_of_month
    end

    def default_to
      today.end_of_month
    end

    # [from, to, error]: the dates asked for when they make a range, and the current month, with why, when they don't. Both blank
    # is the current month and no error.
    def resolve(from, to)
      return [ default_from, default_to, nil ] if blank?(from) && blank?(to)

      from_date = parse(from)
      to_date = parse(to)
      return [ from_date, to_date, nil ] if from_date && to_date && from_date <= to_date

      [ default_from, default_to, ERROR ]
    end

    def blank?(value)
      value.nil? || (value.is_a?(String) && value.strip.empty?)
    end

    # A date as a date field sends it, and nothing else: no other spelling, no year outside the range, no date that isn't one.
    def parse(value)
      year, month, day = value.is_a?(String) ? value.strip.match(DATE)&.captures&.map(&:to_i) : nil
      return unless year&.between?(MIN_YEAR, MAX_YEAR) && Date.valid_date?(year, month, day)

      Date.new(year, month, day)
    end
end
