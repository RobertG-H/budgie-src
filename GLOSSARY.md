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

**Record**:
A Deposit, Spend, Refund or Reallocation: one dated entry that changes the budget's figures. A bank transaction isn't one; filing makes records from it.

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
A real bank or card account that bank transactions come from. Budgie doesn't track what's in it; that's the user's business. It's either imported into from CSV files or synced from a connection: a Splitwise Account holds the user's share of each Splitwise expense, and takes no Import.
_Avoid_: Wallet

**Bank transaction**:
The bank's record of money moving in or out of an account, before Budgie has filed it as one or more Deposits, Spends or Refunds, or ignored it. For a Splitwise Account it's Splitwise's record of the user's share of an expense: what they paid less what they owe, positive when friends owe them. A sync keeps it up to date as the expense is edited, and marks it deleted in Splitwise, never deleting it, when the expense is deleted.
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

**Settle-up**:
Money paid between friends to settle what Splitwise says they owe, which Budgie ignores. It's a transfer between the user's own accounts, so both the Splitwise payment and the e-transfer that settles it are ignored.
_Avoid_: Payment, repayment

**Filing rule**:
A standing instruction, such as "anything from Loblaws goes to Groceries", that files the bank transactions it fits the same way each time, or ignores them. It acts on bank transactions as they come in, and on the unfiled ones when it's saved, never on ones already filed or ignored, and never on those in an Account that has Filing rules off. It ignores numbers and symbols in a description, so "Loblaws #1029" and "Loblaws #1031" are the same to it. Whatever it files or ignores is to review.
_Avoid_: Category rule, mapping, auto-categorisation

**To review**:
A bank transaction that a filing rule filed or ignored and that no person has looked at yet. It counts in the budget's figures straight away and stays to review until it's marked reviewed, a record filed from it is edited, or it's un-filed or un-ignored. A rule filing it again makes it to review again.
_Avoid_: Unconfirmed, unchecked, pending, to check

**Guess**:
The envelope and kind Budgie proposes for an unfiled bank transaction that no filing rule that can act on it fits, from how similar ones were filed. It only suggests, and filing stays the user's.
_Avoid_: Suggestion, prediction
