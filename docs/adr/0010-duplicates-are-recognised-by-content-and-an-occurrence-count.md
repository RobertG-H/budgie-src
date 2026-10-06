# Duplicates are recognised by content and an occurrence count

A CSV row has no bank-supplied ID, and overlapping files are the normal case: CIBC leaves the last one to two business days out of a download and warns that the same transaction can download twice. So a row's identity is a content key, built from its Account, date, signed amount and description (trimmed, whitespace collapsed, case folded), plus an occurrence number. For each key an import adds `max(0, rows in the file − rows already in the Account)`, counting every existing row whether it is filed, ignored or removed, so two identical coffees on one day both come in while a re-imported or overlapping file adds nothing. A unique index on `(account_id, key, occurrence)` is the backstop.

Bank sync adds a second identity, the bank's own `external_id`, unique per Account where it is set. Every row still gets its content key and occurrence at insert, and they are never recomputed, because they record how the row first looked. A sync adopts an existing CSV row whose key matches exactly, setting its `external_id` and keeping its filing, so starting to sync an Account that has CSV history doesn't double-count the seam.

## Considered Options

- **Flag possible duplicates and make the user confirm each one.** Safe, but a routine overlapping import would turn into a chore.
- **Fuzzy matching on a date window, as Actual Budget does.** It copes with a bank editing a description between exports, but a wrong match silently drops a real transaction.
- **An Account is either CSV or sync, never both.** It avoids the seam, but switching to sync would mean a new Account and losing the unfiled rows and history.

## Consequences

The description in the key is only squished and case folded (`BankTransaction.normalize_description`), never cleaned of its numbers and symbols the way a Filing rule reads it (ADR 0015): `Loblaws #1029` and `Loblaws #1031` are different rows, and changing the key's reading would make every re-import see its old rows as new.

If a bank edits a description between two exports, the row comes in a second time as a new unfiled bank transaction, and the user ignores it. The same is true at the seam when a sync's raw description differs from the CSV's. Importing with a wrong format, such as an inverted sign, and then again with the right one doesn't match, because the amounts differ: the first Import is undone first (ADR 0011).
