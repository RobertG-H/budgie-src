<!--
Source: https://daisyui.com/llms.txt
daisyUI version: 5.7.46 (matches app/assets/tailwind/daisyui.mjs and daisyui-theme.mjs)
Fetched: PENDING — curl is blocked in this checkout (see CLAUDE.md), so this file is a placeholder.

Operator, one-time (or whenever the pinned version below changes): run
  curl -sLo docs/daisyui.md https://daisyui.com/llms.txt
then edit the header back in above the fetched content: source URL, the daisyUI version the plugin files
are pinned to, and today's date. Commit the result. A WebFetch summary is not a substitute — this file
must be the verbatim llms.txt, since Claude reads it as reference when adding or changing a daisyUI
component (see CLAUDE.md's Frontend section).
-->

# daisyUI reference (pending fetch)

This file is meant to hold daisyUI's `llms.txt` verbatim, per the header above. Until the operator runs the
`curl` command, use these instead:

- The vendored plugin source itself, `app/assets/tailwind/daisyui.mjs` and `daisyui-theme.mjs` — it's the
  actual shipped CSS-in-JS, more precise than the docs for exact class names, selectors and CSS variables.
- https://daisyui.com/llms.txt and https://daisyui.com/docs/install/rails/ directly.

## Bumping the pinned version

1. Pick a release at https://github.com/saadeghi/daisyui/releases — a real version, not `latest`, so the
   bump is a reviewed, one-line diff rather than something that changes silently.
2. Download it: `gh release download vX.Y.Z --repo saadeghi/daisyui --pattern 'daisyui*.mjs' --dir
   app/assets/tailwind` (overwrites the two vendored files; needs a one-time approval, or the operator runs
   it).
3. Update the version comment in `app/assets/tailwind/application.css` if it has one, and the version
   noted in the header above.
4. Re-fetch this file the same way (`curl -sLo docs/daisyui.md https://daisyui.com/llms.txt`) so it matches
   the new version, and update the header's date.
5. Run the full check suite (`bin/rspec`, `bin/rubocop`, Brakeman, bundler-audit, `bin/importmap audit`) and
   do a visual review of `/styleguide` and the restyled screens — a daisyUI bump can change spacing, default
   colours or component markup. `DESIGN.md` has the contrast ratios to re-check.
