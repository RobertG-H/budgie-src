# Design

Rules for Budgie's UI. They're short and checkable on purpose — grep for the "Don't" list, and glance at
`/styleguide` for the rest. See `CLAUDE.md` for `docs/daisyui.md` (loaded when adding or changing a daisyUI
component) and the full **Visual review** steps.

## Local-development-only rule

> **`/styleguide`, `/dev/sign_in`, the seeded dev user, `.mcp.json` and Playwright MCP are for a developer's
> own machine only.** They must never be reachable in `test`, on the testing host or on the production host.
> Testing and production both run `RAILS_ENV=production`, so every guard checks `Rails.env.development?`,
> never `!Rails.env.production?`. See `CLAUDE.md`'s **Visual review** section for how to use them.

## Colour

Only the theme, through daisyUI's semantic classes (`btn-primary`, `bg-base-200`, `text-error`). No raw
Tailwind palette colours (`gray-*`, `red-*`, `green-*`, …) and no hex values in views — `@theme { --color-*:
initial; }` in `app/assets/tailwind/application.css` makes the raw ones produce nothing, so this is checkable
by trying it, not just by review. Colour is never the only carrier of meaning: pair it with an icon, a word,
or shape, the way an Overspent row also says "Overspent" rather than only turning red.

### The `budgie` theme and its contrast ratios

One theme, `budgie`, `color-scheme: light`, no `--prefersdark`. `--depth: 0` and `--noise: 0`, so daisyUI adds
no shadows or texture — matching **Don't**, below. Values come from the 50–950 scale in `budgie-colors.css`
(kept outside the repo as the source of truth for shades; only the roles below are wired into the theme).
Ratios are WCAG 2.x, computed against the exact sRGB values daisyUI renders (verify visually on `/styleguide`'s
Colours section, which shows every role next to its content colour):

| Role | Colour | `-content` | Ratio | |
| --- | --- | --- | --- | --- |
| `base-100` | white `#ffffff` | `base-content` = `neutral-950` `#212629` | 15.28:1 | |
| `base-200` | `neutral-50` `#f5f8fa` | `neutral-950` | 14.33:1 | |
| `base-300` | `neutral-200` `#dae1e5` | `neutral-950` | 11.56:1 | |
| `primary` | `primary-700` `#006a8d` | white | 6.09:1 | |
| `secondary` | `neutral-600` `#697379` | white | 4.85:1 | |
| `accent` | `primary-400` `#00baf5` | `neutral-950` | 6.80:1 | never used as text on white (2.25:1) |
| `neutral` | `neutral-900` `#353c3f` | `neutral-50` | 10.53:1 | |
| `info` | `primary-300` `#82d7ff` | `primary-950` `#002a3a` | 9.42:1 | |
| `success` | `success-700` `#1e7329` | white | 5.93:1 | |
| `warning` | `warning-400` `#ed9c0a` | `neutral-950` | 6.81:1 | never used as text on white (2.24:1) |
| `error` | `danger-700` `#ac262a` | white | 6.85:1 | `-700`, not `-600`; see below |

Two roles are deliberately darker, or deliberately background-only, than the scale suggests: `accent`
(`primary-400`) and `warning` (`warning-400`) are never text, because on white they're 2.25:1 and 2.24:1,
and `success` uses the `-700` shade because `success-600` with white content is only 4.11:1.

**Why these values:**

1. **`error` is `danger-700`, not `danger-600`.** `danger-600` passes on `base-100` (4.79:1) but fails on
   `base-200` (4.49:1) and `base-300` (3.62:1); `danger-700` passes on all three (6.85:1, 6.42:1, 5.18:1),
   so error text is safe anywhere in the app rather than only on white.
2. **`secondary` (`neutral-600`) and `info` (`primary-300`)** both clear 4.5:1 comfortably, at 4.85:1 and
   9.42:1.
3. **Field borders.** A plain daisyUI input's default border is `base-content` at 20% opacity, ~1.49:1
   against a white field — under the 3:1 WCAG 1.4.11 asks of a UI component's boundary.
   `app/views/components/_field` uses `border-base-content/55` instead (3.11:1) for text inputs, selects and
   textareas. Checkboxes don't need this: `checkbox-primary` and `checkbox-error` set the border colour
   unconditionally (checked or not) to `primary` (6.09:1) and `error` (6.85:1), both already well clear of
   3:1 — confirmed by reading the compiled CSS, since the visual difference between a 1.49:1 and a 3:1+ gray
   border is too subtle to trust by eye.
4. **Muted text** (`text-base-content/70`, used for hints, descriptions and stat labels) clears 4.5:1 on all
   three base surfaces (5.70:1, 5.52:1, 4.97:1). The lighter `/60` daisyUI defaults to for table headers and
   `.stat-title`/`.stat-desc` does not (4.16:1 on `base-100`), so `application.css` overrides table headers to
   70%, and the partials that use stat text set it explicitly.
5. **`max-w-3xl`** and the spacing steps (2/4/6/8) are checked visually on `/styleguide` at 1280px.

## Layout

Mobile-first: design at 375px, add `sm:`/`lg:` for wider. The app shell is a daisyUI `navbar`, with a row of links to the other pages under it once there's a budget (`layouts/_sections`, wrapping on a phone, the current one marked in a bolder weight and `aria-current`), above a centred
`main`; on a phone the budget's currency drops under the app name instead of beside it, so nothing has to
shrink to fit. Content width is `max-w-3xl` by default, with `px-4 sm:px-6`. Spacing uses Tailwind's scale in
steps of 2, 4, 6 and 8 (`gap-4`, `space-y-6`, `mt-8`) — no arbitrary values like `mt-[13px]`. No horizontal
page scroll at 375px: tables are the one place content can outgrow a phone, so they scroll in their own
`overflow-x-auto` wrapper rather than the page, and their cell padding drops to a quarter of daisyUI's below `sm:` so
three money columns fit without that, and to three quarters from `sm:` up, so the month view's seven (with Show details on) fit the page. Tap targets stay comfortable at 375px (daisyUI's default button and field heights; `btn-sm` only where a button sits in a table row, a list row or a row of links, as the Assigned cell's, a bank transaction's Un-file and the month links' do).

## Money and numbers

- Amounts go through the `components/money` partial, which wraps `money(amount, budget:)` (itself
  `number_to_currency`). It turns a negative amount's text red and, when passed `overspent: true`, adds an
  "Overspent" badge — colour is never the only cue.
- An envelope's Available on the month view has a bar under its figure (`components/available_bar`): a native
  `<progress aria-hidden="true">`, `w-16` and right-aligned, with no word for it, since the figure beside it is the text and
  its colour (`progress-success` for plenty, `progress-warning` for a little) and its length say which. Overspent is a full
  `progress-error` bar, and keeps its word in the badge on a line under it (`components/overspent_badge`), so the figure
  stays right-aligned; `money`'s `overspent:` puts the same badge beside a figure elsewhere. An envelope with nothing to
  spend has no bar. It's a `<progress>` and not a styled `div`, since its length would need a `style=` attribute.
- Amount columns and cells are right-aligned with `tabular-nums` (`text-right tabular-nums`).
- Negatives always carry a sign (`-$30.00`); overspending also says so in words.
- The currency code appears once, in the header (`Budget in USD`).
- Budgeting copy uses only the terms `CLAUDE.md` lists: Budget, Envelope, Deposit, Assigned, Spend, Spent,
  Refund, Reallocation, Record, Archive, Account, Bank transaction, CSV format, Import, File, Filing rule, Guess, Ignore,
  Available, Overspent, Ready to Assign, Carried over, Starting balance, and other forms of them (Records, Deposited,
  Refunded, Reallocate, Reallocated, Archived, Unarchive, Assign, Filed, Unfiled, Ignored, Imported, Guessed).

## Components

Prefer daisyUI components and semantic classes first. Reusable UI that needs more than a class goes in a
partial under `app/views/components/`, and the same class string is never copy-pasted across views — the
second use turns it into a partial. The partials:

| Partial | For |
| --- | --- |
| `_flash` | One flash message (`notice`/`alert`/`info`/`warning`), used by the layout and shown for every type on `/styleguide`. |
| `_page_header` | A page's `h1`, optional `badge` beside it, optional description, and actions block (e.g. the "New envelope" button). |
| `_archived_badge` | The "Archived" badge beside an archived envelope's name, on the month view's row and by the title on its page (`_page_header`'s `badge`). A `badge-neutral badge-sm` word, never only a colour, as Overspent isn't. |
| `_money` | An amount in the budget's currency; red and signed when negative, optionally badged Overspent beside it. |
| `_overspent_badge` | The "Overspent" badge, the one place its markup lives: beside a figure through `_money`, and on a line under the Available bar. |
| `_available_bar` | The month view's bar under an envelope's Available figure, and the Overspent badge under it for an Overspent one. It has no word, so it's hidden from assistive technology; its colour and length are the level. |
| `_field` | A labelled form control (`:input`, `:select`, `:textarea`, `:file`, `:checkbox`, or `:radios`, a group of radio buttons under a legend) with an optional hint and error, wired up with matching `aria-describedby`/`aria-invalid`. The block renders the actual `form.*` control and is given the classes and aria attributes to splat onto it. `hide_label` takes the label out of sight but not away from assistive technology, for a control whose place makes its purpose clear, such as an amount inside a table cell. |
| `_empty_state` | What a list shows when it has nothing in it, with an optional title and next action. |
| `_stat_card` | One headline number with a label (e.g. an envelope's Available) and an optional description under it, built on daisyUI's `stats`. It's a plain card: not a link, and it has no word of its own for what's wrong with the number, which is `months/_ready_to_assign`'s job where it matters. |
| `_month_links` | The control for moving between months: Previous, the month's name and Next joined as three `btn btn-sm` in a `join`, and a ghost "This month" beside it when viewing another. A chevron alone below `sm:`, and from `sm:` up the neighbouring month's name; accessible names always carry the month ("Previous month, September 2026"). Previous is shown, disabled and not a link in January of year 1, where there's no month before it. Each page passes a `path` that turns a month into its own address, so the links stay on that page. With `picker: true` (the month view only) the name is a button that opens `_month_picker`; without it the name is plain text, and so is it until the button is revealed by JavaScript. |
| `_month_picker` | The dialog the month view's name opens: a native `<dialog>` the `modal` controller opens, with a year stepper (`‹`, a number input from 1 to 275760, `›`) and a three-column grid of the year's twelve months as links, the viewed one filled with `aria-current` and this calendar month outlined and said in its name, a "This month" button under the grid and Close. The grid is one tab stop (roving `tabindex`) with arrow, Home, End and PageUp/PageDown keys. |
| `_date_range_filter` | A range of dates to filter a list by, inside a page's GET form: From and To as `<input type="date">` through `_field`, the presets (This month, Last month and Last 3 months) as `btn btn-sm` links with the one the range equals filled dark and `aria-current="true"`, and an Apply button. Each preset keeps the page's other filters and sets the two dates, so nothing needs JavaScript. A range that can't be used is the page's alert and the current month, never an empty list. For a state that doesn't use the range, such as the unfiled bank transactions, which are listed whatever their date, `disabled` shows the fields disabled, leaves the presets out and says why in a hint the fields are described by. Used by the Records page and the Bank transactions page. |
| `_record_list` | The bordered list that holds record rows. |
| `_label_badge` | A short neutral word that says what something is, such as Unfiled or Skipped, or which way money went, such as Money in. The word carries the meaning, never the colour. |
| `_record_row` | One record in a `_record_list`, such as a Deposit: its date, its description with any notes as a muted second line, and its amount. A Reallocation also has where the money went or came from, such as "To Groceries", "To Ready to Assign" or "From Dining out", as a muted line of its own, and its amount signed from the page's side. The whole row links to the record's edit page, where it's also deleted, or isn't a link at all for a record that's only read, such as a bank transaction. A list that goes back past a year spells out the year (`with_year`). Its block is more under the description, such as a bank transaction's state, a Guess in a muted line, and what can be done to it, for a row that isn't a link. A `leading` control, such as a checkbox for choosing the row, goes before the date and makes the row a label for it, so the whole row is what's ticked: only for a row that isn't a link, as in the review for filing Guesses. |
| `_row_note` | A muted line under a row's description, such as which Filing rule filed a bank transaction or what a Guess was like ("Guess: like LOBLAWS #1234 → Groceries"). Its block is the line. |
| `_link_row` | One thing in a list that's opened by choosing it, such as a CSV format or a Filing rule: its name, with an optional muted line under it saying more and an optional `badge`, a `_label_badge` word beside the name that says what it is, such as Inactive. The whole row links to where it's opened, and it goes in a `_record_list`. |
| `_sample_grid` | The first rows of a sample file as a numbered table, for choosing columns from: each row has its line and each column its number, a row the format skips is muted and says "Skipped" in a word, and a long cell is cut short. It scrolls by itself when it's wider than the page. |
| `_pager` | Links to the pages either side of the one being looked at, for a list shown a page at a time, newest first, so the next page is "Older" and the one before it "Newer". It's nothing when the list is one page. |
| `_form_actions` | What ends a form: its submit button, the main action, and a Cancel link back to the page it was opened from. The button says "Create Spend" or "Update Spend" unless it's given something else to say, such as "Import". |
| `_delete_button` | A button that deletes a record once a `turbo_confirm` question has been answered yes, sending along any params it's given, such as the page the record was opened from. It says Delete unless it's given another label, for what it takes back, such as Undo. A form of its own, so it goes in a page's header actions. |
| `_panel` | A bordered box that holds things that belong together and are apart from what's around them, such as the bank transaction on the filing form and the Filing rule it offers to make. A `div` unless given another `tag`, such as a `fieldset` for a group of fields with a legend, and a `class` or `data` goes on it. |
| `_modal` | A button that opens a native `<dialog>`, via the `modal` Stimulus controller. |

The month view's Ready to Assign card (`months/_ready_to_assign`) is the one headline number with a caption, so a person doesn't have to work out whether it's good news: "left to assign", "All assigned", "More was assigned than deposited." or "Nothing to assign yet." in words, with the figure it adds up from labelled under it (a `dl` that wraps, `text-xs` labels over `tabular-nums` figures) and "See Deposits", a plain link at its foot, so the card is never one big link. **Warning is for the current month only**: `to_assign?` there is `border-warning bg-warning/10` with a `badge-warning` caption, and in any other month a plain card with a `badge-ghost`; a new budget's empty card is plain with a "New deposit" button, never warning, and over-assigned is `border-error` in every month. The warning is only ever a background or a border, never text on white (2.24:1), and all text on the tinted card stays `base-content`.

A table's least-used columns can go behind one toggle, as the month view's Carried over, Refunded and Reallocated do (`months/_details_toggle`): a `btn btn-sm` above the table, right-aligned, with `aria-pressed` and "Show details" / "Hide details", and a muted hint beside it, left, that says what hiding them means. **The table never moves when the toggle changes**: every hint and label is rendered, stacked in one grid cell with the one that doesn't apply `invisible`, so the row is as tall and wide as the longer in either state. From `sm:` the hidden figures are columns; below it each envelope is its own `<tbody>` with a second full-width row of labelled `text-xs` figures (a `dl`, three columns), there only while details are on, and the first row's bottom border goes while it is. The state is `data-details="on|off"` on `<html>`, read with `in-data-[details=on]:` variants. Every figure in an envelope's row sits on the row's first line (`align-top leading-8`, a line as tall as the Assigned button), so the bar and badge under Available don't pull the others off it.

An envelope's archived state is a word and not a colour: the badge beside its name, and its Assigned as plain text where an envelope in use has the button that opens the input, since it's read-only. The month view lists every archived envelope in a native `<details>` ("Archived envelopes") below the table, bordered like a record list (`rounded-box border border-base-300`), each name a `link` filling a row, and only when the budget has some.

## Interactivity

Turbo Frames and Streams and Stimulus first. Native `<dialog>` (the `_modal` partial) and `<details>` where
they do the job, instead of a JS-built equivalent. No new JS libraries without asking.

An amount edited in place, such as an envelope's Assigned on the month view (`app/views/assignments/`), is a Turbo
Frame that swaps a button showing the amount for an input with Save and Cancel. The button is a `btn btn-sm
text-base font-normal` chip, so it reads as tappable at rest and its figure is the size of the column's others, nudged
with `-mr-2 px-2` so it still lines up with them. The input is `components/field` with `hide_label`. Its form submits to the whole page
(`data-turbo-frame="_top"`) so that saving refreshes every figure on the page with a morph that keeps the scroll
position, and an amount that's refused comes back as a Turbo Stream into the frame.

## Don't

- No gradients, no heavy shadows (`--depth: 0` in the theme already turns these off for daisyUI's own
  components).
- No new colours outside the theme, no raw Tailwind palette classes or hex colours in views (`@theme {
  --color-*: initial; }` makes the former produce nothing; `grep -rnE "gray-|red-|green-|style=|#[0-9a-fA-F]
  {3,8}\b" app/views` should return nothing for both).
- No `style=` attributes for colour or spacing.
- No colour-only status — pair with an icon, a word or shape.
- No UI text set in a size the Tailwind scale doesn't have.
