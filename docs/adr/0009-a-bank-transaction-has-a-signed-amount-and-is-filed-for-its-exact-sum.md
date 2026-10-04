# A bank transaction has a signed amount and is filed for its exact sum

A bank transaction stores one signed `amount`, never 0: positive is money in, negative is money out. Every source carries a sign, and they disagree (Plaid uses + for money out, Finicity and SimpleFIN + for money in, Flinks has separate debit and credit columns), so the sign is normalised once, at the edge: the CSV format reads a file into this convention, and each bank-sync adapter will do the same. A credit card purchase is money out whatever sign its CSV uses. The sign decides what a bank transaction can become: money in is filed as Deposits and Refunds, money out as Spends, and never as a Reallocation, which moves money inside the budget.

Filing creates every record and its link in one database transaction, and the records must add up to the bank transaction's amount, so a bank transaction is unfiled, filed or ignored and is never partly filed. After that the records are ordinary and editable (ADR 0002). Editing one so the total no longer matches doesn't block anything; the bank transaction shows a flag, because "looks the same whether typed in or imported" would be false if a typo fix were refused.

## Considered Options

- **An unsigned `amount` and a `direction` column, as the core tables do.** It would restate what the bank's own sign already says, and the core's rule exists because a table says which way money moved, which a bank transaction's table can't.
- **Partial filing, with a "$60 of $100 filed" remainder.** A Costco charge is $60 and $40 and a paycheck is $2,800 and $200. A remainder state would be a fourth status that every list and every Undo has to handle.
- **Blocking edits to a filed record's amount.** The sum could never drift, but a record would stop behaving like one that was typed in.

## Consequences

A money-out that undoes a Deposit, such as an employer clawing back an overpayment, has nowhere to go: there are no negative Deposits. The user files it as a Spend from an envelope or ignores it.
