# Sample data for local development only, loaded by db/seeds.rb in the development environment. It's the
# user that /dev/sign_in signs in as, with a budget, a few envelopes and a couple of Deposits so the real pages
# have something to show. Running it again changes nothing that's already there.
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
[ this_month.prev_month, this_month ].each do |date|
  budget.deposits.find_or_create_by!(description: "Paycheck", date: date) { |deposit| deposit.amount = 3000 }
end
