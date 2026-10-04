# Budgie

Budgie is an envelope budget: it cares about all the money a person has and which envelope each dollar is allocated to, not about what sits in each bank account.

## The budget

**Budget**:
A user's whole plan: its envelopes, the money coming in, and where that money has been assigned.

**Envelope**:
A named part of the budget, such as Groceries or Rent, that keeps its balance from month to month.
_Avoid_: Category

**Archived envelope**:
An envelope put away once it is finished with, which needs an Available of 0 and nothing dated after this month. It leaves the pickers and the months where it has nothing to show, keeps its history, and can be unarchived.
_Avoid_: Hidden, closed

**Starting balance**:
The amount already in an envelope before Budgie tracked it. It can be negative.

## Money moving

**Deposit**:
New money coming into the budget, such as a paycheck. It lands in Ready to Assign, not in any envelope, in the month it arrives or the month after.
_Avoid_: Income, inflow

**Assigned**:
Money moved from Ready to Assign into one envelope for one month. A new month starts with the previous month's amounts.
_Avoid_: Budgeted

**Spend**:
Money paid out of the budget from one envelope, such as a grocery bill or the rent. An envelope's spends in a month add up to its Spent.
_Avoid_: Spending, expense, purchase, payment, outflow

**Refund**:
Money coming back for something spent from an envelope, such as a store refund or a friend paying you back. It lands in an envelope, not in Ready to Assign.
_Avoid_: Reimbursement, repayment

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
The bank's record of money moving in or out of an account, before Budgie has filed it as one or more Deposits, Spends or Refunds, or ignored it.
_Avoid_: Transaction, statement line, import row

**CSV format**:
How one bank's CSV download is laid out: which columns hold the date, the description and the amount, and which way the sign runs. The user builds it from a sample file and saves it under a name, so later files from that bank read the same way.
_Avoid_: Mapping, template, preset

**Import**:
One CSV file read into one Account, which creates its bank transactions. Only the Account's latest Import can be undone, and only for 24 hours.
_Avoid_: Batch, upload

**Filing**:
Turning a bank transaction into the Deposits, Spends or Refunds it was, which must add up to its amount. Un-filing deletes those records and leaves the bank transaction unfiled.
_Avoid_: Categorising, matching, assigning

**Ignored bank transaction**:
A bank transaction Budgie won't file, such as a card payment between the user's own accounts. It can be un-ignored.
_Avoid_: Hidden, skipped

**Filing rule**:
A standing instruction, such as "anything from Loblaws goes to Groceries", that files the bank transactions it fits the same way each time, or ignores them. It acts on bank transactions as they come in, never on ones already filed.
_Avoid_: Category rule, mapping, auto-categorisation

**Guess**:
The envelope and kind Budgie proposes for an unfiled bank transaction that no filing rule fits, from how similar ones were filed. It only suggests, and filing stays the user's.
_Avoid_: Suggestion, prediction
