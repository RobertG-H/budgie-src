# Import from the header: the file alone. Budgie works out which of the budget's CSV formats reads it and which Account it's for
# (Budget::ImportGuesser), and when both are certain it imports it straight away and lands on the Import's summary, where Undo is
# (ADR 0014, ADR 0011). When they aren't, it shows the whole form with the best offer already chosen and a note on what was guessed, and
# nothing is created: an Import into an uncertain Account can't be caught as a duplicate, since duplicates are judged per Account.
#
# The file isn't kept, so a form that comes back can't hold it: the browser puts it back in the field (the import-file Stimulus controller), and
# when it can't, the form says to choose it again.
class ImportGuessesController < ApplicationController
  # A budget with no CSV format, or no Account, has nothing to guess with: the whole form says what's missing.
  def create
    return redirect_to(new_import_path) unless Current.budget.importable?

    @guess = Budget::ImportGuesser.new(Current.budget).guess(file) if file
    return import_it if @guess&.complete?

    @account_fixed = false
    @account = @guess&.account
    @import = Budget::Import.new(account: @guess&.account, csv_format: @guess&.csv_format, file_name: file&.original_filename)
    @import.errors.add(:base, "Choose a file to import.") unless file
    render "imports/new", status: :unprocessable_content
  end

  private
    # Both are certain, so it's imported as the form would, with the same Import#run, which reads the file again: one more read of a file of at
    # most 5,000 rows, to keep `run` unchanged. It can only be refused by something that changed since the file was read.
    def import_it
      file.rewind if file.respond_to?(:rewind)
      @import = Budget::Import.new(account: @guess.account, csv_format: @guess.csv_format, file_name: file.original_filename)

      if @import.run(file)
        redirect_to import_path(@import),
          notice: "Imported #{@import.file_name} into #{@import.account.name}, read with the #{@import.csv_format.name} CSV format."
      else
        @account = @guess.account
        @account_fixed = false
        render "imports/new", status: :unprocessable_content
      end
    end

    # The file that was sent, if one was: anything else in its place is no file.
    def file
      return @file if defined?(@file)

      sent = params.expect(import: [ :file ])[:file]
      @file = sent if sent.respond_to?(:original_filename)
    end
end
