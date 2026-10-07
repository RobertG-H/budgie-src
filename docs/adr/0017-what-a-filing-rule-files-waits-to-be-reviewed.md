# What a Filing rule files waits to be reviewed

A Filing rule still files or ignores a bank transaction as soon as it arrives (ADR 0012), but every bank transaction a rule filed or ignored is **to review** until a person has looked at it. It's counted in the header beside the unfiled count, listed in a To review state on the Bank transactions page, and cleared with Mark reviewed, one row at a time or a page at a time. ADR 0012 counted on the Import summary to catch a wrong rule, but the summary says only how many rows rules filed and ignored, never which. A wrongly ignored bank transaction is in no figure at all, so a rule whose text is too broad could ignore money for months and nobody would notice.

- **Every outcome is reviewed**, Spend, Refund and Deposit as well as Ignore. Ignore is the one that disappears from the budget, but a text that's too broad misfiles a Spend as easily as it ignores one ("amazon" → Household catching a gift), and a wrong envelope's Spent is easy to miss.
- **No rule is ever exempt.** What goes wrong is how broad a rule is, not how long it has been right: a rule that has been right 26 times can still fit a new merchant whose description contains its text. Mark reviewed works on a page at a time, which keeps the cost low.
- **What counts as reviewed:** Mark reviewed, saving an edit to a record filed from the bank transaction, and un-filing or un-ignoring it, after which it's no longer the rule's. Each time a rule files or ignores it again, whether when it arrives or in a sweep, it's to review again. Rows a sweep files are reviewed like an Import's, because the person was shown a count and never the rows.
- **The figures don't wait.** Ready to Assign, Spent and Available include what rules filed, reviewed or not.

## Considered Options

- **Hold the row: a rule's match stays unfiled, with the rule's choice made, until a person approves it.** ADR 0012 rejected this already. A 200-row Import would mean 200 approvals before the figures were right, forgetting to approve would leave money out of the budget, and a rule would become a pre-ticked Guess.
- **A switch on each rule between filing and asking first.** ADR 0012 rejected this too. Every rule would have to answer the question.
- **Visibility only: list the rows on the Import summary, and filter the Bank transactions page by rule.** That shows what happened only to someone who goes looking. Nothing stays in view until it's been looked at.
- **Trust earned by a rule: after some number of reviews with no un-file, what it files skips review.** Nobody would see this happen. "It stopped asking me" is exactly the silent change this decision exists to prevent.

## Consequences

- The list grows with every Import a rule acts on, so reviewing is what rules now cost, and Mark reviewed on a page at a time keeps that cost low. If it becomes a chore, the next step is a per-rule "Ask me to review what it files" switch, which is not the filing-or-suggesting switch ADR 0012 rejected.
- Bank transactions that rules filed or ignored before this decision start out to review, once.
- ADR 0012 still holds: rules file immediately. Its "until someone notices" now has a place to happen: the To review list.
