# Undo reaches only the latest Import, for 24 hours

An Import commits as soon as the file is checked, with no preview step, so Undo is the safety net for a wrong pick. It removes an Import's filed records, then its bank transactions, then the Import (ADR 0002), after a confirmation that lists the counts. It reaches only the Account's most recent Import, because a later Import's skipped duplicates (ADR 0010) point at rows from earlier ones: undoing an older Import would silently lose rows that a later file skipped. It is available only for 24 hours after the Import ran, so it can't wipe out weeks of filing.

Rows that bank sync brings in aren't an Import and can't be undone. The next sync would only bring a deleted row back, so the user ignores a row or un-files it instead.

## Considered Options

- **A preview before committing.** It needs the file, or its parsed rows, held between two requests, and every Import would pay for the rare mistake. Hard refusals before anything is created, and a summary with the date range and money in and out, cover most mistakes.
- **Undo only while none of the Import's bank transactions has been filed or ignored.** Undo would never delete a record, but a mistake noticed after filing thirty rows would mean un-filing each by hand, and it would amend ADR 0002.
- **Any Import, at any time.** It breaks the duplicates that later Imports skipped, and one click could delete a month of work.

## Consequences

An Import older than 24 hours, or one with a newer Import after it, stays. Its rows are put right one at a time, by un-filing, ignoring or filing again.
