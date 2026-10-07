# Sample data for local development only, loaded by db/seeds.rb in the development environment. It's the
# user that /dev/sign_in signs in as, with a budget, a few envelopes, a couple of Deposits, what's assigned from
# them, what's spent, what came back, what was moved between envelopes and back to Ready to Assign, an archived
# envelope with history, a CSV format, Filing rules, an Account with an Import and an Account synced from Splitwise, so the real pages have something to show. Running it
# again changes nothing that's already there.
#
# The user has no Identity, and its email isn't a real one, so nobody can sign in as it through Google.
user = User.find_or_create_by!(email: Dev::USER_EMAIL) { |new_user| new_user.name = "Dev Budgie" }
budget = Budget.find_or_create_by!(user: user) { |new_budget| new_budget.currency = "USD" }

# A spread of balances: thousands, cents, zero and a negative.
{
  "Bills" => -30,
  "Fuel" => 0,
  "Groceries" => 250,
  "Rent" => 1234.50,
  "Dining out" => 45.25
}.each do |name, starting_balance|
  budget.envelopes.find_or_create_by!(name: name) { |envelope| envelope.starting_balance = starting_balance }
end

# A Paycheck on the 1st of last month and of this month. The month before those has none, so the month view
# shows Ready to Assign carried over from last month to this one, and from nothing before that.
this_month = Date.current.beginning_of_month
last_month = this_month.prev_month
[ last_month, this_month ].each do |date|
  budget.deposits.find_or_create_by!(description: "Paycheck", date: date) { |deposit| deposit.amount = 3000 }
end

# What's assigned to each envelope last month and this month: $2,800 and then $3,100, against $3,000 deposited in
# each, so Ready to Assign reads $200 last month and $100 this month, before the archived envelope and the Reallocation
# to Ready to Assign below change them. Bills gets nothing, which keeps it Overspent and shows an Assigned of $0.00, and
# the month before last has nothing assigned at all.
{
  "Rent" => [ 1500, 1500 ],
  "Groceries" => [ 700, 800 ],
  "Fuel" => [ 300, 350 ],
  "Dining out" => [ 300, 450 ]
}.each do |name, amounts|
  envelope = budget.envelopes.find_by!(name: name)
  [ last_month, this_month ].zip(amounts).each do |month, amount|
    envelope.assignments.find_or_create_by!(month: month) { |assignment| assignment.amount = amount }
  end
end

# What's spent from each envelope last month and this month, as [ description, day of the month, amount ]. Days stay
# within the 28 every month has. Dining out is spent past what it has this month, which leaves it Overspent, and Fuel
# has nothing last month, so its page for that month has no Spends to list. Rent is paid on the 1st, and Bills has
# nothing, so it stays Overspent on its Starting balance alone.
{
  "Groceries" => [
    [ [ "Loblaws", 3, 182.40 ], [ "Costco", 12, 240.15 ], [ "Farm Boy", 24, 96.80 ] ],
    [ [ "Loblaws", 2, 164.20 ], [ "Farm Boy", 9, 88.35 ] ]
  ],
  "Rent" => [
    [ [ "Landlord", 1, 1500 ] ],
    [ [ "Landlord", 1, 1500 ] ]
  ],
  "Fuel" => [
    [],
    [ [ "Shell", 4, 58.40 ], [ "Petro-Canada", 11, 61.15 ] ]
  ],
  "Dining out" => [
    [ [ "Pizza Nova", 6, 38.50 ], [ "Sushi Kai", 19, 72.25 ] ],
    [ [ "Brunch", 3, 54.10 ], [ "Date night", 5, 187.30 ], [ "Birthday dinner", 8, 340.65 ], [ "Takeout", 10, 126.45 ] ]
  ]
}.each do |name, spends_by_month|
  envelope = budget.envelopes.find_by!(name: name)
  [ last_month, this_month ].zip(spends_by_month).each do |month, spends|
    spends.each do |description, day, amount|
      envelope.spends.find_or_create_by!(description: description, date: month + (day - 1)) { |spend| spend.amount = amount }
    end
  end
end

# Money that came back to Groceries this month, as a store refund would: it raises what's Available there, and nothing
# else changes, Ready to Assign least of all. It's the only one, so every other envelope's page has no Refunds section.
budget.envelopes.find_by!(name: "Groceries").refunds
  .find_or_create_by!(description: "Loblaws return", date: this_month + 5) { |refund| refund.amount = 18.75 }

# Money moved from Groceries, which has some left, to Dining out, which is Overspent: $20 covers part of it, so Dining
# out is still Overspent, with less to cover. Only Groceries and Dining out have a Reallocations section on their pages.
groceries = budget.envelopes.find_by!(name: "Groceries")
budget.envelopes.find_by!(name: "Dining out").incoming_reallocations
  .find_or_create_by!(from_envelope: groceries, description: "Covering the takeout", date: this_month + 11) { |reallocation| reallocation.amount = 20 }

# Money moved from Fuel, which has some left, back to Ready to Assign: $50 of this month's raises it from $100 to $150, and
# lowers what's Available in Fuel by the same. It's the only one, so Fuel is the only envelope whose page lists a
# Reallocation to Ready to Assign, and this month's Deposits page has a Reallocations section.
budget.envelopes.find_by!(name: "Fuel").ready_to_assign_reallocations
  .find_or_create_by!(description: "Unspent fuel money", date: this_month + 13) { |reallocation| reallocation.amount = 50 }

# An envelope that's been put away, with history: $40 assigned to it last month and all spent, so it has nothing Available
# and nothing after last month, and could be archived. Last month's view shows it, with an Archived badge, and this
# month's doesn't, since none of its figures is anything but zero there. Its $40 lowers Ready to Assign, from $200 to $160
# last month and from $150 to $110 this month, as every envelope's Assigned does. It's archived once it has its records,
# since an archived envelope takes no more, and only when it's new, so one the developer has unarchived stays so.
old_gym = budget.envelopes.find_or_create_by!(name: "Old gym") do |envelope|
  envelope.assignments.build(month: last_month, amount: 40)
  envelope.spends.build(description: "Membership", date: last_month + 14, amount: 40)
end
# A Filing rule for it, made while it's in use, since an archived envelope takes no new ones: it's inactive once the envelope is archived, which is
# what the Filing rules page flags.
budget.filing_rules.create!(text: "gym membership", outcome: "spend", envelope: old_gym) if old_gym.previously_new_record?
old_gym.archive! if old_gym.previously_new_record?

# A CSV format that reads spec/fixtures/files/signed-sample.csv, so a developer can build a format from that file to see
# the builder's grid and preview, and import it. It's the bank's header row to skip, then the date, the description and one
# signed amount. It's only made when there isn't one by its name, so a developer's changes to it stay.
sample_bank = budget.csv_formats.find_or_create_by!(name: "Sample bank") do |csv_format|
  csv_format.assign_attributes(rows_to_skip: 1, column_count: 3, date_column: 1, date_format: "YYYY-MM-DD", description_columns: [ 2 ],
    amount_style: "signed", amount_column: 3)
end

# Two Filing rules for what's in that file: "loblaws" files as a Spend from Groceries, and "coffee shop" ignores. They're only made when
# there isn't one by their text, so a developer's changes to them stay.
groceries = budget.envelopes.find_by!(name: "Groceries")
budget.filing_rules.find_or_create_by!(text: "loblaws") { |rule| rule.assign_attributes(outcome: "spend", envelope: groceries) }
budget.filing_rules.find_or_create_by!(text: "coffee shop") { |rule| rule.outcome = "ignore" }

# An Account with the sample file imported into it with that format: five bank transactions, money in and money out, and a sixth
# row of 0 that's skipped. It's only imported while the Account has no Import, and the bank transactions are only filed and ignored
# then, straight after, so what a developer has done to them since, such as undoing the Import or un-filing one, isn't redone by
# seeding again.
chequing = budget.accounts.find_or_create_by!(name: "Chequing")
if chequing.imports.none?
  # The rules above file Loblaws as a Spend from Groceries, of its whole amount, which counts in Groceries' September like any other Spend,
  # and ignore Coffee shop, as the Import brings them in: the Import's summary says so, and the Account's page shows which rule did it.
  sample = Rails.root.join("spec/fixtures/files/signed-sample.csv")
  sample.open { |file| chequing.imports.build(csv_format: sample_bank, file_name: sample.basename.to_s).run(file) or raise "The sample file wasn't imported." }

  # Hydro is filed by hand, as a split: $50.00 from Bills and the other $15.50 from Rent, which add up to its $65.50, so a bank
  # transaction filed as several records has something to show. Paycheck and Hydro rebate stay unfiled, so the Unfiled list has some.
  hydro = chequing.bank_transactions.find_by!(description: "Hydro")
  bills, rent = budget.envelopes.where(name: %w[ Bills Rent ]).order(:name)
  hydro_entry = Budget::Filing::Entry.new(bank_transaction: hydro,
    drafts: [ Budget::Filing::Draft.for(hydro, envelope_id: bills.id, amount: 50), Budget::Filing::Draft.for(hydro, envelope_id: rent.id, amount: 15.5) ])

  Budget::Filing.new(budget).file([ hydro_entry ]) or raise "The sample wasn't filed: #{(hydro_entry.errors.full_messages + hydro_entry.drafts.flat_map { |draft| draft.errors.full_messages }).to_sentence}"
end

# An Account synced from Splitwise, with a connection whose token isn't real: nothing signs in to Splitwise in development unless the app is registered there, so
# Sync now says Splitwise doesn't accept the sign-in, but it gives the Accounts page and an Account's page a synced Account to show. It's only made when there isn't one for
# its connection, so a developer's changes to it stay. Its name can't clash with an Account a developer made by hand.
splitwise = budget.bank_connections.find_or_create_by!(provider: Budget::BankConnection::SPLITWISE, login_id: "1000000") do |connection|
  connection.assign_attributes(login_name: "Dev B.", access_token: "development-token-not-real", read_from: this_month)
end
splitwise_account = budget.accounts.find_or_create_by!(bank_connection: splitwise) do |account|
  account.assign_attributes(name: "Splitwise (sample)", external_account_id: splitwise.login_id, files_with_rules: false)
end

# What a sync would have brought into it, one of each thing a bank transaction from Splitwise can be, so the Bank transactions page and the Account's page have them
# all to show: unfiled ones (money in and out), filed ones, one whose amount changed since it was filed and one whose sign did, one deleted in Splitwise before it was
# filed and one after, and a settle-up, which arrives ignored. They have no Import, as a sync's don't. Only made while the Account has none, and filed and changed straight
# after, so what a developer has done to them since isn't redone by seeding again.
if splitwise_account.bank_transactions.none?
  expense = ->(number, description, amount, day) do
    splitwise_account.bank_transactions.create!(external_id: (1_000 + number).to_s, description: description, amount: amount, date: this_month + day)
  end
  # As the filing form starts: money in from Splitwise is a Refund, and money out a Spend.
  file = lambda do |bank_transaction, envelope|
    entry = Budget::Filing::Entry.new(bank_transaction: bank_transaction, drafts: [ Budget::Filing::Draft.for(bank_transaction, envelope_id: envelope.id) ])
    Budget::Filing.new(budget).file([ entry ]) or raise "The Splitwise sample wasn't filed: #{entry.full_messages.to_sentence}"
  end
  # An envelope of its own, so what's filed from them doesn't change the figures of the envelopes above.
  shared = budget.envelopes.find_or_create_by!(name: "Shared") { |envelope| envelope.starting_balance = 200 }

  expense.(1, "Dinner at Nonna's", 50, 2)
  expense.(2, "Cottage groceries", -45, 3)
  file.(expense.(3, "Brunch with friends", 30, 1), shared)
  file.(expense.(4, "Gas up north", -30, 1), shared)

  # Filed, and then changed in Splitwise: the amount, and the sign with the size the same. Neither touches the Refund it was filed as.
  movie_night = expense.(5, "Movie night", 20, 4)
  file.(movie_night, shared)
  movie_night.update!(amount: 25)
  taxi = expense.(6, "Taxi home", 15, 4)
  file.(taxi, shared)
  taxi.update!(amount: -15)

  # Deleted in Splitwise: one that was never filed, which leaves the Unfiled state, and one that was, which keeps its Refund until it's un-filed.
  expense.(7, "Deleted lunch", -12, 2).update!(removed_at: Time.current)
  concert = expense.(8, "Concert tickets", 40, 3)
  file.(concert, shared)
  concert.update!(removed_at: Time.current)

  expense.(9, "Jane paid me back", 50, 5).update!(ignored_at: Time.current)
  # As if it had synced a little while ago, so the Account's page has a time to say.
  splitwise.update_columns(synced_at: 25.minutes.ago)
end
