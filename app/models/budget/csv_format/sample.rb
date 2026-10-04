# The first rows of a sample file, which is what a person builds a CSV format from: the grid the builder numbers, and the
# column count a format takes from it. A sample is only ever held for one request: it's never kept.
class Budget::CsvFormat::Sample
  # The rows the grid shows.
  GRID_ROWS = 10

  # A row of the sample: where it started in the file, its cells, and whether the format skips it.
  Row = Data.define(:line, :cells, :skipped)

  attr_reader :refusal

  # `file` is anything that can be read, such as an uploaded file. `rows_to_skip` is how many of its rows the format being
  # built skips, which the grid says, and which decides which row the column count is taken from.
  def initialize(file, rows_to_skip: 0)
    @source = Budget::CsvFormat::Source.new(file)
    @rows = @source.each_row.first(rows_to_skip + GRID_ROWS).each_with_index.map do |(line, cells), index|
      Row.new(line: line, cells: cells, skipped: index < rows_to_skip)
    end
  rescue Budget::CsvFormat::Source::Unreadable => unreadable
    @refusal = unreadable.refusal
    @rows = []
  end

  def grid_rows
    @rows.first(GRID_ROWS)
  end

  # The most columns any row in the grid has, so every row fits it.
  def width
    grid_rows.map { |row| row.cells.size }.max.to_i
  end

  # The format's column count: how many columns the first row it reads has. Without one, such as a sample that's all skipped
  # rows, the widest row in the grid.
  def column_count
    first_read = @rows.find { |row| !row.skipped && row.cells.any?(&:present?) }
    (first_read ? first_read.cells.size : width).presence
  end

  # Reads the whole sample with a CSV format, so the preview can't read it any other way than an Import would.
  def read(csv_format)
    csv_format.read(@source)
  end
end
