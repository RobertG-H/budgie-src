# Why a file can't be read: the line of the first row that can't be, or none for something wrong with the whole file.
#
# `about_the_file` says it's about the file itself, whichever CSV format reads it: it isn't UTF-8, it's over 2 MB, it isn't CSV, it has too many rows or
# it has nothing in it. Every other refusal is this CSV format's, such as the wrong number of columns or a date it can't read, which another format
# might read without trouble. A file that no CSV format reads is explained with the first kind once, and with the second per format.
Budget::CsvFormat::Refusal = Data.define(:line, :reason, :about_the_file) do
  def initialize(line:, reason:, about_the_file: false)
    super
  end

  def message
    line ? "Line #{line}: #{reason}" : reason
  end

  def about_the_file?
    about_the_file
  end
end
