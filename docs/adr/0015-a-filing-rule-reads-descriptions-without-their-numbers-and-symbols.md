# A filing rule reads descriptions without their numbers and symbols

A bank's description carries things that change from one bank transaction to the next: a store number (`Loblaws #1029`), a reference (`Presto Fare/Shwqfxpddf`), an e-transfer's id (`Internet Banking E-TRANSFER 106121984683 James Graham-Hu`). A rule made from one of those with the whole description as its text never fits the next, which defeats the point of a rule. So a Filing rule compares the description and its own text after both go through one cleaning, and it is still `include?` on plain text, with no pattern.

The cleaning, after the squish and case fold that make a content key: a single last word after a `/` is dropped; `# / * \ _ ,` become spaces; punctuation at a word's ends is trimmed; and a word is dropped when it has no letter, has three or more digits, or is one character. Hyphens, apostrophes, ampersands, at signs and dots inside a word stay, so `e-transfer`, `graham-hu`, `7-eleven` and `3m` survive. It changes nothing when applied again, which a rule's text needs: the text is saved cleaned, and the form's untouched default text always fits its own bank transaction.

## Considered Options

- **A smarter default text only.** The form would suggest the description up to its first number, and matching would stay a substring. It can't keep what follows a number, so every e-transfer would be one rule whoever sent it.
- **A wildcard in the text.** `internet banking e-transfer * james graham-hu` is explicit, but it is a syntax people have to learn, and it reverses "a rule's text is text and never a pattern".
- **Fall back to the raw description when nothing is left.** Guess does this. A rule for one bank transaction's id would never fit another, so a description that is only an id has no rule to offer.

## Consequences

A person can't make a rule that depends on a particular number: `dollarama #1595` is saved as `dollarama`. The Amount condition on the Filing rules page still tells things apart, and there is no opt-out. A single word after a final `/` is always treated as a reference, so `e-transfer/james` keeps only `e-transfer` (with more words after the `/`, nothing is dropped).

The cleaning is its own function (`BankTransaction.normalize_for_matching`). `normalize_description` is unchanged because the content key is built from it and keys are never recomputed (ADR 0010): changing it would make every re-import see its old rows as new. Guess keeps its own word rule and the database's `normalized_description` (ADR 0013); it already ignores words with a digit.

A migration cleans the stored text of rules made before, with its own copy of the cleaning. It never deletes a rule: one that would collide with another once cleaned, or fall under three characters, keeps its old text, and `FilingRule#fits?` cleans the stored text it matches, so every rule keeps fitting from the moment of the deploy. A rule that was made from `loblaws #1` and one from `loblaws #2` are the same rule from now on, and the most recently edited takes the cleaned text.
