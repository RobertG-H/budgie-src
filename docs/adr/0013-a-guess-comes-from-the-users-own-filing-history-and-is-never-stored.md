# A guess comes from the user's own filing history and is never stored

When no Filing rule that can act on it fits, a Guess for an unfiled bank transaction is worked out, when it is shown, from how that Budget's similar bank transactions were filed. Nothing leaves the server, the result is deterministic and can say why ("like LOBLAWS #1234 → Groceries"), and there is no Guess table to go stale when a record is edited or a rule changes, as no table stores a balance either.

## Considered Options

- **An LLM call** with the description, amount and the user's envelope names. It copes with a brand-new merchant, but it sends bank descriptions to a third party, costs money on every Import, isn't deterministic or easy to test, and needs a key and new infrastructure.
- **A provider's category or merchant name mapped to the user's envelopes.** It exists only with bank sync, since CSV rows have none, and the user's envelopes aren't a standard taxonomy (`docs/research/bank-sync-aggregators.md`).

## Consequences

A merchant the Budget has never filed gets no Guess. Either option can be added later behind the same seam as its own roadmap item, with its own ADR.
