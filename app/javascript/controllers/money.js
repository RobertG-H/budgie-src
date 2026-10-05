// An amount as the budget shows it, in its currency unit: "$82.45", "-$1,234.50". It's for the controllers that keep a figure up to date as a form
// changes, in the same words the server starts it with (`money` in ApplicationHelper), so there's one place that spells it.
export function formatMoney(unit, amount) {
  const figure = Math.abs(amount).toLocaleString("en", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  return `${amount < 0 ? "-" : ""}${unit}${figure}`
}
