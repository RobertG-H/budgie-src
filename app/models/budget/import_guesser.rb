# Works out which CSV format reads a file and which Account it's for, from the budget's own CSV formats and Accounts, so that an Import from the
# header can run without asking when both are certain (ADR 0014). It's the one place that's decided, and it never creates or changes anything.
#
#   Budget::ImportGuesser.new(budget).guess(file)  # => a Budget::ImportGuess
#
# It reads the file's text once, as a Budget::CsvFormat::Source, and runs each of the budget's CSV formats' reader over it. Only a format whose
# reading has no refusal reads it cleanly. A format whose column count differs refuses on the first row, and the reader goes row by row, so the cost
# is the formats that fit, once each, inside the reader's own 2 MB and 5,000-row limits; it's one query for the formats, one for the Accounts, and
# one more each for choosing between several, so the number of queries doesn't grow with the rows or the formats' rows.
#
# 1. Format. None reads it cleanly: no format. One does, or several that read exactly the same rows (two formats that name the same columns): that's
#    the format, certain; among identical ones the one used by the most recent Import wins, and then the newest format. Several that read it differently:
#    not certain, and the one offered is the one the most recent Import used among them, then the newest format.
# 2. Account. The budget's Accounts whose default CSV format is that format, or, for formats that read exactly the same rows, any of them, since they're
#    one format to a person: the Import is then read with the Account's own. Exactly one is the Account, certain. Several: not certain, and the one
#    imported into most recently is offered (then the first alphabetically). None: no Account.
# 3. Complete means the format is certain and the Account is certain. This is one step stricter than "the Account most recently imported into": an
#    unconfirmed Import into the wrong Account can't be caught as a duplicate, since duplicates are judged per Account.
class Budget::ImportGuesser
  def initialize(budget)
    @budget = budget
  end

  # `file` is anything that can be read, such as an uploaded file, or the text of one.
  def guess(file)
    csv_formats = @budget.csv_formats.alphabetical.to_a
    return Budget::ImportGuess.nothing if csv_formats.empty?

    source = Budget::CsvFormat::Source.new(file)
    readings = csv_formats.to_h { |csv_format| [ csv_format, csv_format.read(source) ] }
    clean, refused = readings.partition { |_, reading| reading.refusal.nil? }

    clean.empty? ? nothing_reads_it(refused) : guess_from(clean)
  rescue Budget::CsvFormat::Refused => refused
    Budget::ImportGuess.nothing(file_refusal: refused.refusal)
  end

  private
    # No format reads the file: what's wrong with the file itself when every format says so, once, and otherwise each format's own first refusal.
    def nothing_reads_it(refused)
      refusals = refused.map { |csv_format, reading| Budget::ImportGuess::Rejection.new(csv_format: csv_format, refusal: reading.refusal) }

      if refusals.all? { |rejection| rejection.refusal.about_the_file? }
        Budget::ImportGuess.nothing(file_refusal: refusals.first.refusal)
      else
        Budget::ImportGuess.nothing(refusals: refusals)
      end
    end

    def guess_from(clean)
      chosen = choose_format(clean.map(&:first))
      # Certain when every format that reads it reads the same rows and the same number of rows of 0, which is the case for one.
      format_certain = clean.map { |_, reading| [ reading.rows, reading.zero_rows ] }.uniq.one?
      # Formats that read exactly the same rows are one format to a person, so an Account may have any of them as its default, and the Import
      # is read with the Account's own. Several that read it differently are only the one that's offered.
      same = format_certain ? clean.map(&:first) : [ chosen ]
      accounts = @budget.accounts.importable.where(default_csv_format_id: same.map(&:id)).alphabetical.to_a
      account = choose_account(accounts)

      Budget::ImportGuess.new(
        csv_format: account ? same.find { |csv_format| csv_format.id == account.default_csv_format_id } : chosen,
        format_certain: format_certain, account: account, account_certain: accounts.one?, refusals: [], file_refusal: nil
      )
    end

    # The format the most recent Import used among `csv_formats`, and when none of them has been used, the newest.
    def choose_format(csv_formats)
      return csv_formats.first if csv_formats.one?

      used = @budget.imports.where(csv_format_id: csv_formats.map(&:id)).order(created_at: :desc, id: :desc).pick(:csv_format_id)
      csv_formats.find { |csv_format| csv_format.id == used } || csv_formats.max_by { |csv_format| [ csv_format.created_at, csv_format.id ] }
    end

    # The Account imported into most recently among `accounts`, and when none of them has had an Import, the first.
    def choose_account(accounts)
      return accounts.first if accounts.size <= 1

      used = @budget.imports.where(account_id: accounts.map(&:id)).order(created_at: :desc, id: :desc).pick(:account_id)
      accounts.find { |account| account.id == used } || accounts.first
    end
end
