# The record behind Spent is a Spend

Money paid out of the budget from an envelope is recorded as a Spend (`Budget::Spend`, in `budget_spends`), and "Spend" is a UI term next to the month view's Spent. The build plan called it `Spending`, but that's a mass noun: there's no "a spending", and the UI needs a noun for one record ("New spend", "Delete this spend?"). Spend also completes the pattern where the record is a noun and the month's total is its past tense: Deposit and Deposited, Refund and Refunded, Spend and Spent.

## Considered Options

- **Spending, as the plan had it.** It reads well as a heading but not as one record, and the table would be `budget_spendings`.
- **Purchase.** It's natural for shopping but wrong for rent, bills and taxes, which are some of the biggest envelopes.
- **Expense.** A Splitwise expense is already an expense, and Budgie will file Splitwise expenses as Spends.
- **Payment.** A card payment between the user's own accounts is a bank transaction Budgie ignores, and a Splitwise settle-up is a payment too.
