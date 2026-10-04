# A Reallocation is two tables, one per destination

Moving money out of an envelope is a Reallocation, and it lands either in another envelope or back in Ready to Assign. The two are recorded in two tables: `budget_envelope_reallocations` (`Budget::EnvelopeReallocation`, with `from_envelope_id` and `to_envelope_id`) and `budget_ready_to_assign_reallocations` (`Budget::ReadyToAssignReallocation`, with `envelope_id`). "Reallocation" is the UI word and the glossary term for both. The table says where the money landed, the way Deposit and Refund say whether money lands in Ready to Assign or in an envelope, so every column in both is NOT NULL, each has plain check constraints, and no behaviour depends on a type column or a missing value. The second table is shaped exactly like a Spend, so it shares `DatedEnvelopeRecord`.

One form creates either, chosen by its To field. A saved Reallocation's destination can't change, because that would move the record between tables: delete it and add another.

## Considered Options

- **One table with a nullable `to_envelope_id`, where null means Ready to Assign.** What the money did would depend on a missing value, and every query would have to ask.
- **One table plus a one-to-one child table holding the destination envelope.** No column is null, but a missing row is a null in disguise, and every create is two inserts.
- **Ready to Assign as a pseudo-envelope row.** It would show up in envelope lists and pickers and need special handling everywhere, and it isn't an envelope in real life.
- **Lowering this month's Assigned instead.** An Assignment is one positive figure per envelope per month, so it can't hand back money carried over from earlier months. Correcting this month's plan and moving money that's already in the envelope are different acts.

## Consequences

Lowering this month's Assigned and a Reallocation to Ready to Assign can give the same balances. That overlap is accepted, and the month view keeps the two apart: Assigned is the plan for the month, and Reallocated is money moved. The calculator adds a fixed number of grouped queries for each table, so the query count still doesn't grow with months or envelopes.
