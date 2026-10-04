# How a sample file reads with the CSV format being built, as far as it's been chosen: the first rows as they'd be imported,
# or why they can't be, so a person sees a wrong sign or a swapped DD/MM before saving. It reads with the same reader an
# Import does.
class Budget::CsvFormat::Preview
  # How many of the sample's rows it shows.
  ROWS = 5

  attr_reader :csv_format, :sample

  # `sample` is nil when no file has been chosen.
  def initialize(csv_format, sample)
    @csv_format = csv_format
    @sample = sample
  end

  # What there is to show:
  # - :none, because no sample has been chosen
  # - :unreadable, because the sample can't be read as a file
  # - :incomplete, because the format isn't chosen enough to read with yet
  # - :refused, because the format can't read a row, which is `refusal`
  # - :ready, with `rows`
  def status
    @status ||= if sample.nil? then :none
    elsif sample.refusal then :unreadable
    elsif problems.any? then :incomplete
    elsif reading.refusal then :refused
    else :ready
    end
  end

  # What's still to choose, other than the name, which has nothing to do with how rows read.
  def problems
    @problems ||= begin
      csv_format.valid?
      csv_format.errors.reject { |error| error.attribute == :name }.map(&:full_message)
    end
  end

  def refusal
    sample&.refusal || reading.refusal
  end

  def rows
    reading.rows.first(ROWS)
  end

  # Every row the format reads, of which `rows` shows the first few.
  def total
    reading.rows.size
  end

  def zero_rows
    reading.zero_rows
  end

  private
    def reading
      @reading ||= sample.read(csv_format)
    end
end
