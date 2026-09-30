# Budgie

Budgie is an envelope budget: it cares about all the money a person has and which envelope each dollar is allocated to, not about what sits in each bank account.

## The budget

**Budget**:
A user's whole plan: its envelopes, the money coming in, and where that money has been assigned.

**Envelope**:
A named part of the budget, such as Groceries or Rent, that keeps its balance from month to month.
_Avoid_: Category

**Starting balance**:
The amount already in an envelope before Budgie tracked it. It can be negative.

## Money moving

**Deposit**:
Money coming into the budget, such as a paycheck. It isn't in any envelope until it is assigned.
_Avoid_: Income, inflow

**Assigned**:
Money moved from Ready to Assign into one envelope for one month.
_Avoid_: Budgeted

**Spent**:
Money that left an envelope.
_Avoid_: Expense, outflow

**Refund**:
Money returned to an envelope, such as a store refund. It goes back to the envelope, not to Ready to Assign.

**Reallocation**:
Money moved out of an envelope on a given day, into another envelope or back to Ready to Assign. Money going from Ready to Assign into an envelope is Assigned, never a Reallocation.
_Avoid_: Transfer, move

## Balances

**Available**:
What is in an envelope right now, including everything carried over from earlier months. Negative means overspent.

**Overspent**:
An envelope whose Available balance is below zero.

**Ready to Assign**:
Deposited money that hasn't been assigned to an envelope yet. It carries over between months and can be negative.

**Carried over**:
The balance brought forward from the previous month. Nothing resets at month end.

## Importing

**Account**:
A real bank or card account that bank transactions come from. Budgie doesn't track what's in it; that's the user's business.
_Avoid_: Wallet

**Bank transaction**:
The bank's record of money moving in or out of an account, before Budgie has filed it as a Deposit, Spent or Refund, or ignored it.
_Avoid_: Transaction, statement line, import row
