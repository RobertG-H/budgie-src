# Why a file can't be read: the line of the first row that can't be, or none for something wrong with the whole file.
Budget::CsvFormat::Refusal = Data.define(:line, :reason) do
  def message
    line ? "Line #{line}: #{reason}" : reason
  end
end
