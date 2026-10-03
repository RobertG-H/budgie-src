# Each month starts with last month's Assigned

Assigned is one figure per envelope per month, and most envelopes get the same amount every month, so entering them all again each month is a chore. So when a month begins, Budgie copies each envelope's Assigned from the month before into every envelope with nothing assigned yet for the new month, and the user changes only what differs. A copy is an ordinary Assigned amount, and each month keeps its own: changing a past month changes only that month's Assigned, and the Carried over and Available after it follow. A one-off amount, such as December's gifts, is copied into January too, and the user lowers it there.

## Considered Options

- **An "Assign the same as last month" button.** One more thing to do every month, usually to change nothing.
- **An amount that repeats until it's changed, worked out rather than copied.** Changing a past month would also change every month after it, up to the next change, and stopping an amount would need an explicit zero.
- **A monthly amount on each envelope that new months copy from.** It handles one-offs without a second edit, but it's another figure to keep in step with Assigned. It can still be added later by changing what the copy reads from.

## Consequences

A background job, not the user, writes the copied amounts, so a month that hasn't begun shows only what was entered ahead for it.
