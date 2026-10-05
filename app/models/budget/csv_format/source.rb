# The rows of a CSV file, before any CSV format has read them: its text, which has to be UTF-8 and no bigger than 2 MB, with
# any BOM stripped, and each row's cells with the line it started on. The reader and the builder's sample both start here,
# so they agree on what a file is.
class Budget::CsvFormat::Source
  MAX_BYTES = 2.megabytes

  # `file` is anything that can be read, such as an uploaded file, or the text of one.
  def initialize(file)
    @text = text_of(file)
  end

  # Each row's first line and its cells, in the file's order. A row with a line break in a quoted cell takes more than one
  # line, which is counted, so the line is what a person would find in an editor. Rows nothing was said about, such as a
  # blank line, are rows without cells.
  def each_row
    return enum_for(:each_row) unless block_given?

    line = 0

    begin
      csv = CSV.new(@text)

      csv.each do |cells|
        start = line + 1
        line += csv.line.count("\n")
        yield start, cells
      end
    rescue CSV::MalformedCSVError => error
      raise Budget::CsvFormat::Refused, Budget::CsvFormat::Refusal.new(line: line + 1, reason: "isn't valid CSV (#{error.message.sub(/ in line \d+\.?\z/, "")}).", about_the_file: true)
    end
  end

  private
    # Reads one byte past the most a file can be, which is enough to tell that it's over without reading all of it.
    def text_of(file)
      data = file.respond_to?(:read) ? file.read(MAX_BYTES + 1) : file.to_s.byteslice(0, MAX_BYTES + 1)
      text = data.to_s.dup.force_encoding(Encoding::UTF_8)

      refuse("The file is over #{MAX_BYTES / 1.megabyte} MB.") if text.bytesize > MAX_BYTES
      refuse("The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again.") unless text.valid_encoding?

      text.delete_prefix("\uFEFF")
    end

    def refuse(reason)
      raise Budget::CsvFormat::Refused, Budget::CsvFormat::Refusal.new(line: nil, reason: reason, about_the_file: true)
    end
end
