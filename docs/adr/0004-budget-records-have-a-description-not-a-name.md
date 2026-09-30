# Budget records have a description, not a name

Deposits, Spends and Refunds each have a `description`: one short line saying what the money was, such as "Paycheck", "Loblaws" or "Dinner at Pai", whether that's who was paid or what it was for. Anything longer goes in `notes`. The build plan gave each a `name` that meant something different on each table: where a deposit came from, what spending was for, and who issued a refund. A record doesn't have a name in real life, and every outside source that will fill the field gives a description: the bank feeds in `docs/research/bank-sync-aggregators.md` and Splitwise expenses.

## Considered Options

- **A payee, as YNAB and Actual Budget have, or `payer` and `payee` split by direction.** Each says exactly who, but "Rent" isn't a payee, and neither is a Splitwise expense's "Dinner at Pai".
- **Keep `name`.** An envelope has a name, but a deposit doesn't, and the field would still mean three different things.
