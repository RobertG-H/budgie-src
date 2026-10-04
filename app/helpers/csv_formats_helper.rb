module CsvFormatsHelper
  # How a CSV format reads a file, in a sentence a person can check against their file, such as "Date in column 1 as
  # MM/DD/YYYY. Description in column 2. Amount in column 3, with money out as a negative amount."
  def csv_format_summary(csv_format)
    columns = csv_format.description_columns
    description = "Description in #{"column".pluralize(columns.size)} #{columns.to_sentence}."
    amount = case csv_format.amount_style
    when "signed" then "Amount in column #{csv_format.amount_column}, with money out as a negative amount."
    when "in_and_out" then "Money in is in column #{csv_format.money_in_column}, and money out is in column #{csv_format.money_out_column}."
    when "direction"
      "Amount in column #{csv_format.amount_column}, with money in when column #{csv_format.direction_column} says #{csv_format.money_in_value}."
    end

    [ "Date in column #{csv_format.date_column} as #{csv_format.date_format}.", description, amount, ("The sign is inverted." if csv_format.invert_sign) ].compact.join(" ")
  end

  # A date as a person reads it, spelled out so that a month can't be mistaken for a day: "Sep 3, 2026".
  def spelled_date(date)
    date.strftime("%b %-d, %Y")
  end

  # The same with the time of day, for when something ran: "Sep 3, 2026 at 11:08 AM".
  def spelled_time(time)
    time.strftime("%b %-d, %Y at %-l:%M %p")
  end

  # What's added to the question before deleting a CSV format that's some Accounts' default, which are left with none: " It's the default for 2
  # Accounts, which will have none." Nothing when it's no Account's, since nothing changes then.
  def default_for_accounts_note(csv_format)
    count = csv_format.default_for_accounts.count
    return "" if count.zero?

    " It's the default for #{pluralize(count, "Account")}, which will have none."
  end
end
