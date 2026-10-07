# Splitwise is synced as an Account

Splitwise is synced like a bank. Connecting it makes an Account, and each Splitwise expense the person is part of becomes a bank transaction in that Account, whose signed amount is the person's net share of it: what they paid less what they owe (Splitwise's `net_balance`). It is positive when friends owe them, which is money in, filed as a Refund or a Deposit, and negative when they owe, which is money out, filed as a Spend. So a Splitwise expense is not a new kind of thing. It's a bank transaction, and everything that already works for one works for it: filing, splitting across envelopes, ignoring, un-filing, Guesses and "File N as guessed" (ADR 0009, ADR 0013).

The card charge for a shared dinner is filed from the bank's Account for its full amount, as it is now. The two are never paired, and together they come out right: a $100 Spend from the card charge and a $50 Refund from Splitwise leave $50 spent on the dinner.

- **A share counts when the Splitwise expense is made**, in the month of its date, and not when it's settled. What friends owe sits in the Splitwise Account, whose balance Budgie doesn't track (ADR 0001).
- **A settle-up is a transfer between the person's own accounts.** A Splitwise payment (`payment: true`) arrives ignored, and the e-transfer that settles it is ignored too, like a card payment between Accounts. So simplified debts, one e-transfer for many expenses, and settling months later need nothing from Budgie.
- **Everything is reviewed.** A Splitwise Account starts with its Filing rules off (ADR 0012), so its review queue is the Bank transactions page's Unfiled state for that Account.

## The connection

A sign-in to Splitwise is a `Budget::BankConnection` (`budget_bank_connections`), built here for its first provider and shaped so a bank-sync provider fits later. It belongs to its budget and never to a user, and holds the provider, the provider's id for the login (the Splitwise user's id) and its name for display ("Robert G."), the access token, the date to read expenses from, the sync marker and when it last synced (both empty until a sync runs), and whether it needs reconnecting. It is unique on budget, provider and login, and every foreign key is `ON DELETE RESTRICT`.

An Account has a nullable `bank_connection_id` and `external_account_id`, unique per connection and either both or neither. A Splitwise connection has exactly one Account, whose external id is the Splitwise user's id. An Account that is synced takes no CSV Import, in the UI or from a crafted request: a file read into it would count some of what Splitwise brings twice.

The connection is made by Budgie's own OAuth 2 authorization-code flow, not through OmniAuth: nothing here decides who a person is. The person chooses the Account's name and the date to read from, is sent to Splitwise with a random `state` kept in the session, and on the way back the callback refuses a `state` that isn't the one that was sent, keeps nothing when they decline, swaps the code for a token, reads the current user, and creates the connection and its Account in one database transaction. Reconnecting the same Splitwise user, after Disconnect or once the token stops working, gives the same connection a new token and keeps the Account and its bank transactions; a different Splitwise user is a new connection with a new Account. Disconnecting forgets the token and keeps everything else.

The token is encrypted with Active Record encryption, its keys read from the environment, and is never shown in a page, a log or an error. The Splitwise API is for non-commercial use, which an invite-only personal budget is.

## Considered Options

- **Cash basis: Spent is the full charge, and the friend's repayment is a Refund when the cash arrives.** It is the simplest to describe, but a repayment has to be divided across envelopes and months it can't see, and under simplified debts it can't even tell which expenses it's for. It also makes the month of a shared dinner wrong until it's settled.
- **Splitwise expenses in their own table, with their own link tables to the Deposits, Spends and Refunds they were filed as.** This is what ADR 0002 said would happen. It would need a second filing operation, a second review page, a second Undo and a second set of Guesses for what is, once a share is worked out, a dated signed amount with a description. Making it a bank transaction costs no new table of records.
- **A holding envelope for what friends owe.** It would put money Budgie doesn't have in an envelope, and it would need a record to move it out when a friend paid, which is the pairing that can't be done reliably.

## Consequences

- Envelopes count what friends owe before it's paid: a $50 Refund lands in the month of the Splitwise expense, though the e-transfer that pays it arrives later.
- A settle-up's e-transfer has to be ignored and not filed as a Deposit, or the money would be counted twice. Budgie doesn't tell it from any other e-transfer (scenario 16), so the person ignores it, and a Filing rule on its description isn't the tool, since it would fit every e-transfer from that person.
- A bank transaction can't be partly ignored (ADR 0009), so an over-payment that includes something outside Splitwise can't be split into an ignored part and a filed one (scenario 8).
- The Splitwise Account's own balance, what friends owe the person, is never shown, as for any Account (ADR 0001).
- A share in another currency isn't synced, and the sync counts it as skipped (scenario 13).

## The scenarios

These are the 16 cases #41 set, and how each comes out. None counts the same money twice.

1. **I paid, split evenly.** The −$100 card charge is a $100 Spend from Dining out. The +$50 Splitwise share is a $50 Refund to Dining out, in the month of the expense's date. Jane's +$50 e-transfer is ignored, and her settle-up arrives ignored.
2. **Someone else paid.** The −$40 Splitwise share is a $40 Spend from Groceries in the month of the expense. My −$40 e-transfer, months later, is ignored, and so is the settle-up.
3. **Settling many at once.** Each of the 14 shares is filed as it arrives, into Groceries, Gas, Dining out or Accommodation, and my own card charges are filed in full. The $312.47 e-transfer and its settle-ups are ignored, so the settling touches no envelope.
4. **Settling months later.** Each month's shares were filed in their own months as they arrived. In March, the e-transfer and the settle-up are ignored, so no past month changes then.
5. **Simplify debts.** Budgie reads only my net share of each expense and never `repayments[]`, so who pays whom doesn't matter. Alice's e-transfer is ignored as a settle-up.
6. **One e-transfer, several settle-ups.** The three settle-ups arrive ignored, and the one e-transfer is ignored. Nothing needs pairing.
7. **Netting across directions.** Each expense was filed in its own direction. Jane's $30 and the settle-ups are ignored.
8. **Partial or over payment.** If Jane pays $25 of $50, the e-transfer and the settle-up are ignored, and the $25 she still owes is the Splitwise Account's business. If she sends $60 including a $10 concert ticket that isn't in Splitwise, a bank transaction can't be partly ignored (ADR 0009). The person ignores it and enters a $10 Refund by hand, or adds the ticket to Splitwise so its share syncs.
9. **Settled outside the bank.** For cash or a partner's account, only the settle-up exists, and it's ignored. For an e-transfer with no settle-up recorded, the e-transfer is ignored all the same: Splitwise's balance is wrong until someone records it, which is Splitwise's business (ADR 0001).
10. **The bank amount differs.** They're never paired. The card charge is filed as the bank has it, tip included, or split across Groceries and Household for the $412 Costco run. The Splitwise share is filed as Splitwise has it. One Splitwise expense covering several card charges ("Airbnb + groceries") is one share, split across envelopes on the filing form.
11. **I paid entirely for someone else.** My owed share is 0, so the net is +$100: a $100 Refund to the envelope the card charge was filed from, and none of it is my Spent.
12. **Edits and deletes after filing.** The sync updates the bank transaction in place and never a record. A changed share on a filed one shows "Doesn't add up". A deleted one shows "Deleted in Splitwise" with Un-file, and a restore clears that. A past month's figures change only when the person changes its records, as editing a past Spend does today.
13. **Another currency.** A share in another currency isn't synced, and the sync counts it as skipped. The card charge in the budget's currency is filed in full, and the person enters a Refund by hand for the friends' share if they want one.
14. **Connecting with history.** Shares dated before the read-from date are never read. A settle-up for one arrives ignored like any other, but its e-transfer shouldn't be ignored: the person files it as a Refund, to the envelope the old charge was filed from, or as a Deposit. Starting the date where the bank transactions start keeps this to debts from before Budgie.
15. **The money never comes back.** Delete the expense in Splitwise, or change the share, and it flows through as in scenario 12. Un-file the Refund, and the whole charge stays Spent.
16. **Ordinary e-transfers.** Budgie doesn't tell them apart. The person files rent from a subletter or a Marketplace sale as a Deposit or a Refund, and ignores the settle-ups. A Filing rule on the e-transfer's description would fit all of them, so it isn't the tool for this.
