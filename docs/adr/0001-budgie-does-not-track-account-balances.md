# Budgie doesn't track account balances

Budgie is an envelope budget: it cares about all the money a person has and which envelope it's allocated to, not what sits in each bank account. So an Account exists only as the source of bank transactions (for CSV import, deduplication and, later, bank sync), with no balance, no reconciliation, and no link from a Deposit, Spend or Refund to an account. Keeping each account's balance right is the user's business.

## Considered Options

- **Full accounts with balances and reconciliation, as YNAB does.** Rejected: it's a much bigger product, and it makes every hand-entered record need an account, which the core budget doesn't.
- **No accounts at all, with a saved CSV mapping standing in for the source.** Rejected: deduplication and bank sync both need to know which real account a bank transaction came from.
