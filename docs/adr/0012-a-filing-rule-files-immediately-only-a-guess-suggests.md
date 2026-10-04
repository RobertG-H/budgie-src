# A filing rule files immediately; only a guess suggests

A Filing rule files a matching bank transaction as soon as an Import or a sync creates it: the records are made and the bank transaction is filed, with no confirmation. Remembering how the user filed something and then filing the next one the same way is the whole point of a rule, and the safety nets already exist: the Import summary says how many rows rules filed, Undo reaches the Account's latest Import (ADR 0011), and un-filing puts a bank transaction back. A Guess has no such track record, so it only suggests.

## Considered Options

- **Suggest only, pre-filling the filing form for a one-click confirm.** Nothing changes unseen, but "automatic" shrinks to pre-fill, and a 200-row Import still means 200 confirmations.
- **A switch on each rule between filing and suggesting.** Every rule would have to answer the question, and the Filing rules page would explain two behaviours.

## Consequences

A wrong or too-broad rule misfiles every bank transaction it fits in the next Import until someone notices. The rule's text is shown, and editable, when it is made, so it can be trimmed then, and a bank transaction shows which rule filed it. Editing or deleting a rule never changes what it already filed (ADR 0002), so fixing those means un-filing and filing again.
