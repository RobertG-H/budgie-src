# A Deposit can count toward next month

A month's Deposits aren't known until the month is over, but its envelopes need Assigned amounts from the 1st. So a Deposit has a `month` as well as a `date`: the month whose Ready to Assign it counts toward, which is the month of its date or the month after. Someone living on last month's money marks each paycheck for next month, so on the 1st Ready to Assign holds exactly what came in the month before, and all of it is already in hand. The month defaults to the month of the date and is chosen per Deposit, so a user can get a month ahead gradually, one paycheck at a time. YNAB4 called this "Income for next month".

## Considered Options

- **Assign next month's envelopes from this month's Ready to Assign, as YNAB does today.** It needs no new column, but nothing records that a paycheck is meant for next month, so the month view shows it as Ready to Assign in the month it arrived and invites the user to spend the cushion.
- **Hold for next month, as Actual Budget does.** A separate record that moves part of Ready to Assign into the next month. Ready to Assign already carries over, so the Deposit's own month says the same thing where the money comes in.
- **A budget-wide setting that every Deposit counts toward the month after its date.** Turning it on would move every past Deposit and rewrite every past month's Ready to Assign.
- **Expected Deposits to assign against.** Ready to Assign and Available would be guesses until the money arrives, and a short paycheck would leave envelopes holding money that never came.
