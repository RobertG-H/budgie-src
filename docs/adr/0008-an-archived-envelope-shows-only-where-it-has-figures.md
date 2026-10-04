# An archived envelope shows only where it has figures

An envelope that's finished with can be archived. It's stored as a nullable `archived_at` timestamp on `budget_envelopes`, the way an Invite's status comes from `accepted_at` and `revoked_at`, and unarchiving clears it. Archiving is judged against the current month, whichever month's page it's done from: Available must be 0 in it, and nothing may be dated after it for the envelope (no Assigned entered ahead, no Spend, Refund or Reallocation), so nothing is left in an envelope that's about to be put away.

An archived envelope is hidden from pickers, takes no new Assigned, Spend, Refund or Reallocation, and is skipped when a new month copies last month's Assigned. In the month view its row shows, with an "Archived" badge, in any month where one of its figures isn't zero, and is hidden in any month where they all are. So past months still show what they showed and still add up to their Assigned and Ready to Assign, and the envelope is gone from the months where it has nothing to say. Archived envelopes are listed at the bottom of the month view, and their names stay reserved.

## Considered Options

- **A flag that hides the envelope in every month.** A past month's rows would stop adding up to its Assigned and Ready to Assign, since the archived envelope's amounts still count.
- **The month it's archived from, stored on the envelope.** Hiding from the month it was archived in would hide the row holding its last activity, such as the Reallocation that emptied it, and half of a move would be missing from that month. Using the month after fixes that, but a later edit to an old record could leave money in a month where the envelope is hidden.
- **A separate table of archivals.** It has no null column, but every query for an envelope has to join it.
- **Hiding every envelope that is empty in a month.** Ruled out for active envelopes in [Specify the core build tickets](https://github.com/RobertG-H/budgie-src/issues/35): it hides an envelope exactly when you'd assign to it. An archived envelope can't be assigned to, so hiding it when empty is right for it alone.

## Consequences

Nothing can hide in an archived envelope. If a change to one of its old records makes a later month non-zero, its row appears in that month. Archiving takes the budget's row lock, as starting a new month does, so the monthly copy can't land on an envelope as it's archived.
