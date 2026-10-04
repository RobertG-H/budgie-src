# Sample data for local development only, loaded by db/seeds.rb in the development environment. It's the
# user that /dev/sign_in signs in as, with a budget, a few envelopes, a couple of Deposits, what's assigned from
# them, what's spent, what came back, what was moved between envelopes and back to Ready to Assign, an archived
# envelope with history, a CSV format and an Account with an Import, so the real pages have something to show. Running it again changes nothing that's
# already there.
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
old_gym.archive! if old_gym.previously_new_record?

# A CSV format that reads spec/fixtures/files/signed-sample.csv, so a developer can build a format from that file to see
# the builder's grid and preview, and import it. It's the bank's header row to skip, then the date, the description and one
# signed amount. It's only made when there isn't one by its name, so a developer's changes to it stay.
sample_bank = budget.csv_formats.find_or_create_by!(name: "Sample bank") do |csv_format|
  csv_format.assign_attributes(rows_to_skip: 1, column_count: 3, date_column: 1, date_format: "YYYY-MM-DD", description_columns: [ 2 ],
    amount_style: "signed", amount_column: 3)
end

# An Account with the sample file imported into it with that format: five bank transactions, money in and money out, and a sixth
# row of 0 that's skipped. It's only imported while the Account has no Import, and the bank transactions are only filed and ignored
# then, straight after, so what a developer has done to them since, such as undoing the Import or un-filing one, isn't redone by
# seeding again.
chequing = budget.accounts.find_or_create_by!(name: "Chequing")
if chequing.imports.none?
  sample = Rails.root.join("spec/fixtures/files/signed-sample.csv")
  sample.open { |file| chequing.imports.build(csv_format: sample_bank, file_name: sample.basename.to_s).run(file) or raise "The sample file wasn't imported." }

  # Left unfiled, filed and ignored, so the Unfiled list and the Account's page have each to show. Loblaws is a Spend from Groceries,
  # of its whole amount, which counts in Groceries' September like any other Spend. Hydro is a split: $50.00 from Bills and the other
  # $15.50 from Rent, which add up to its $65.50, so a bank transaction filed as several records has something to show. Coffee shop is
  # ignored. Paycheck and Hydro rebate stay unfiled.
  bank_transactions = chequing.bank_transactions.index_by(&:description)

  loblaws = bank_transactions.fetch("Loblaws")
  loblaws_entry = Budget::Filing::Entry.new(bank_transaction: loblaws, drafts: [ Budget::Filing::Draft.for(loblaws, envelope_id: budget.envelopes.find_by!(name: "Groceries").id) ])

  hydro = bank_transactions.fetch("Hydro")
  bills, rent = budget.envelopes.where(name: %w[ Bills Rent ]).order(:name)
  hydro_entry = Budget::Filing::Entry.new(bank_transaction: hydro,
    drafts: [ Budget::Filing::Draft.for(hydro, envelope_id: bills.id, amount: 50), Budget::Filing::Draft.for(hydro, envelope_id: rent.id, amount: 15.5) ])

  # Both at once, which is what the operation is for.
  entries = [ loblaws_entry, hydro_entry ]
  Budget::Filing.new(budget).file(entries) or raise "The sample wasn't filed: #{entries.flat_map { |entry| entry.errors.full_messages + entry.drafts.flat_map { |draft| draft.errors.full_messages } }.to_sentence}"

  bank_transactions.fetch("Coffee shop").ignore
end
