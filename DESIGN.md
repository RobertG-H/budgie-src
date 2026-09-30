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

Mobile-first: design at 375px, add `sm:`/`lg:` for wider. The app shell is a daisyUI `navbar` above a centred
`main`; on a phone the budget's currency drops under the app name instead of beside it, so nothing has to
shrink to fit. Content width is `max-w-3xl` by default, with `px-4 sm:px-6`. Spacing uses Tailwind's scale in
steps of 2, 4, 6 and 8 (`gap-4`, `space-y-6`, `mt-8`) — no arbitrary values like `mt-[13px]`. No horizontal
page scroll at 375px: tables are the one place content can outgrow a phone, so they scroll in their own
`overflow-x-auto` wrapper rather than the page, and their cell padding halves below `sm:` so three money
columns fit without that. Tap targets stay comfortable at 375px (daisyUI's default button and field heights).

## Money and numbers

- Amounts go through the `components/money` partial, which wraps `money(amount, budget:)` (itself
  `number_to_currency`). It turns a negative amount's text red and, when passed `overspent: true`, adds an
  "Overspent" badge — colour is never the only cue.
- Amount columns and cells are right-aligned with `tabular-nums` (`text-right tabular-nums`).
- Negatives always carry a sign (`-$30.00`); overspending also says so in words.
- The currency code appears once, in the header (`Budget in USD`).
- Budgeting copy uses only the terms `CLAUDE.md` lists: Budget, Envelope, Deposit, Assigned, Spent, Refund,
  Available, Overspent, Ready to Assign, Carried over, Starting balance.

## Components

Prefer daisyUI components and semantic classes first. Reusable UI that needs more than a class goes in a
partial under `app/views/components/`, and the same class string is never copy-pasted across views — the
second use turns it into a partial. The partials:

| Partial | For |
| --- | --- |
| `_flash` | One flash message (`notice`/`alert`/`info`/`warning`), used by the layout and shown for every type on `/styleguide`. |
| `_page_header` | A page's `h1`, optional description, and actions block (e.g. the "New envelope" button). |
| `_money` | An amount in the budget's currency; red and signed when negative, optionally badged Overspent. |
| `_field` | A labelled form control (`:input`, `:select`, `:textarea` or `:checkbox`) with an optional hint and error, wired up with matching `aria-describedby`/`aria-invalid`. The block renders the actual `form.*` control and is given the classes and aria attributes to splat onto it. |
| `_empty_state` | What a list shows when it has nothing in it, with an optional title and next action. |
| `_stat_card` | One headline number with a label (e.g. Ready to Assign), built on daisyUI's `stats`. |
| `_modal` | A button that opens a native `<dialog>`, via the `modal` Stimulus controller. |

## Interactivity

Turbo Frames and Streams and Stimulus first. Native `<dialog>` (the `_modal` partial) and `<details>` where
they do the job, instead of a JS-built equivalent. No new JS libraries without asking.

## Don't

- No gradients, no heavy shadows (`--depth: 0` in the theme already turns these off for daisyUI's own
  components).
- No new colours outside the theme, no raw Tailwind palette classes or hex colours in views (`@theme {
  --color-*: initial; }` makes the former produce nothing; `grep -rnE "gray-|red-|green-|style=|#[0-9a-fA-F]
  {3,8}\b" app/views` should return nothing for both).
- No `style=` attributes for colour or spacing.
- No colour-only status — pair with an icon, a word or shape.
- No UI text set in a size the Tailwind scale doesn't have.
