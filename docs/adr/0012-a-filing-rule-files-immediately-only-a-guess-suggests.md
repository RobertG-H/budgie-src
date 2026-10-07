# A filing rule files immediately; only a guess suggests

A Filing rule files a matching bank transaction as soon as an Import or a sync creates it: the records are made and the bank transaction is filed, with no confirmation. Remembering how the user filed something and then filing the next one the same way is the whole point of a rule, and the safety nets already exist: the Import summary says how many rows rules filed, Undo reaches the Account's latest Import (ADR 0011), and un-filing puts a bank transaction back. A Guess has no such track record, so it only suggests.

## Considered Options

- **Suggest only, pre-filling the filing form for a one-click confirm.** Nothing changes unseen, but "automatic" shrinks to pre-fill, and a 200-row Import still means 200 confirmations.
- **A switch on each rule between filing and suggesting.** Every rule would have to answer the question, and the Filing rules page would explain two behaviours.

## Rules act when a bank transaction arrives, and once when a rule is saved

A rule acts on a bank transaction as an Import creates it, and never again: not on un-filing, un-ignoring or an edit, or un-filing a row a rule filed would file it again at once. The one other time is when a rule is saved, which can also file the unfiled bank transactions that are already there, so a rule made after an Import tidies that Import up too. That is a choice the person makes with a box ticked by default, after being told how many it fits, and it only reaches the bank transactions where the saved rule is the most specific one that fits, so the order rules run in is the same either way. It never touches one that is filed or ignored.

## Except in an Account whose Filing rules are off

An Account can be set to keep Filing rules off it (`files_with_rules`), for one where a person wants to look at every bank transaction themselves, such as the Splitwise Account, where every share of an expense should be reviewed before it becomes a record. So a rule acts on arrival, except in an Account whose Filing rules are off: an Import into it applies none, a sweep leaves its bank transactions alone, and a rule pinned to it is inactive, as one for an archived envelope is. It's a setting on the Account and not on each rule, because an "Any account" rule would otherwise still need to know which Accounts to skip. Guesses still help there, since a rule that won't file a bank transaction has no reason to hide its Guess. The setting is read only when a rule would act, so turning it on again files nothing that's already there, and turning it off leaves what rules already filed as it is.

## Consequences

A wrong or too-broad rule misfiles every bank transaction it fits in the next Import until someone notices. Everything a rule files or ignores is to review until a person has looked at it (ADR 0017), because the Import summary's count never said which rows they were. The rule's text is shown, and editable, when it is made, so it can be trimmed then, and a bank transaction shows which rule filed it. Editing or deleting a rule never changes what it already filed (ADR 0002), so fixing those means un-filing and filing again.
