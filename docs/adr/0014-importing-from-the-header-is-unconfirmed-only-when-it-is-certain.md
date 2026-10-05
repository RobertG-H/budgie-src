# Importing from the header is unconfirmed only when it is certain

The header's Import takes a file and nothing else: Budgie works out which of the budget's CSV formats reads it and which Account it's for, and when it is certain of both it imports the file at once, with no form and no confirmation, and lands on the Import's summary. An Import may run unconfirmed because it can be taken back: Undo is on the summary beside what the Import did, for 24 hours while it is the Account's latest (ADR 0011), and the summary now says which Account and CSV format it used, for every Import, so a wrong guess is seen straight away.

It is unconfirmed only when each guess is certain, and certain means something exact:

- **The CSV format** is certain when exactly one of the budget's formats reads the file cleanly, or when several do and read exactly the same rows (two formats that name the same columns). It is not certain when several read it cleanly and differently, such as a date that is valid as both DD/MM and MM/DD.
- **The Account** is certain when exactly one Account has that format as its default (`default_csv_format`). For formats that read exactly the same rows, an Account may have any of them as its default, since they are one format to a person, and the Import is read with that Account's own.

Otherwise the whole form comes back (File, CSV format and Account, all required) with the best offer already chosen and a note on what was guessed, and nothing is created. A file that no format reads says why, format by format, and points to the CSV format builder.

## Why the Account has to be certain, and not just the most likely

The first idea was to take the Account that was imported into most recently. That is a step too loose: duplicates are judged per Account (ADR 0010), so an unconfirmed Import into the wrong Account can't be caught as a duplicate. The same statement imported into the wrong Account is simply new rows, and then it is imported again into the right one, doubling every figure. When two Accounts share a bank's format (two cards from one bank), the file could be for either, so it asks.

## Considered Options

- **Always show the form.** It is the existing Account → Import flow, which stays. It makes the common case, one Account for one bank's format, as many steps as the rare one.
- **Import into the most recently imported Account when the format is certain.** Fewer questions, and a silent duplicate when two Accounts share a format.
- **Keep the file between two requests so a confirmation step can run it.** Needs the file or its rows held between requests, which Budgie doesn't do (the file isn't kept). The browser holds the chosen file instead and puts it back in the form when one comes back.
- **A mark on an Import that came from a guess.** It would need a column for what is already visible on the summary, so there isn't one.

## Consequences

The Import is made by the same `Budget::Import#run` that the form uses, which reads the file again: one more read of a file of at most 5,000 rows, accepted to keep `run` unchanged. Which Account a file is for depends on `default_csv_format`, which an Account gets from its first Import or by hand, so a person with two Accounts on one bank's format is asked every time, which is the cost of never importing into the wrong one unconfirmed.
