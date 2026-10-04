# Raised to stop reading a file, carrying why: the Refusal that says which row couldn't be read, or what's wrong with the whole file.
# Reading catches it and gives the Refusal back, so a caller sees a refusal and never this.
class Budget::CsvFormat::Refused < StandardError
  attr_reader :refusal

  def initialize(refusal)
    @refusal = refusal
    super(refusal.message)
  end
end
