import { Controller } from "@hotwired/stimulus"
import { formatMoney } from "controllers/money"

// One record's "Edit details" on the filing form (app/views/bank_transaction_filings/_record.html.erb): the description, date, amount, a
// Deposit's month and notes, which sit under a closed <details> because they're rarely changed. It does two things. It keeps the line under
// "Edit details" in step with the fields, in the same words the server starts it with (BankTransactionsHelper#filing_details_summary), so closing
// it isn't a mystery: "LOBLAWS #1234 · Oct 3, 2026 · $82.45", with ", counts toward November" for a Deposit saved for the month after its
// date. And it opens whatever <details> holds a field the browser says is invalid, since the browser can't focus a field in a closed one and
// File would silently do nothing. The `invalid` event doesn't bubble, so it's caught on the way down (`:capture`).
export default class extends Controller {
  static targets = [ "summary" ]
  static values = { unit: String }

  connect() {
    this.update()
  }

  update() {
    if (!this.hasSummaryTarget) return

    const description = this.field("description")?.value.trim().replace(/\s+/g, " ")
    const date = this.parseDate(this.field("date")?.value)
    const amount = parseFloat(this.field("amount")?.value)

    let summary = [
      description,
      date && this.spell(date),
      Number.isNaN(amount) ? null : formatMoney(this.unitValue, amount)
    ].filter(Boolean).join(" · ")

    const month = this.countsTowardMonth(date)
    if (month) summary += `, counts toward ${month}`

    this.summaryTarget.textContent = summary
  }

  // Opens the <details> the invalid field is in, so that the browser can show what's wrong with it.
  reveal(event) {
    const details = event.target.closest("details")
    if (details) details.open = true
  }

  field(name) {
    return this.element.querySelector(`[name$='[${name}]']`)
  }

  // The month a Deposit counts toward, when it isn't its date's: only while the Deposit's month choice is showing, as it is for a Deposit.
  countsTowardMonth(date) {
    const chosen = this.element.querySelector("input[type=radio][name$='[month]']:checked")
    if (!date || !chosen || chosen.closest("[hidden]")) return null

    const month = this.parseDate(chosen.value)
    if (!month || (month.getUTCFullYear() === date.getUTCFullYear() && month.getUTCMonth() === date.getUTCMonth())) return null

    const format = month.getUTCFullYear() === date.getUTCFullYear() ? { month: "long" } : { month: "long", year: "numeric" }
    return month.toLocaleDateString("en", { ...format, timeZone: "UTC" })
  }

  // A date field's value, which is YYYY-MM-DD when it's a date at all, as a date in UTC so that no time zone moves it.
  parseDate(value) {
    const match = /^(\d{4,6})-(\d{2})-(\d{2})$/.exec(value || "")
    if (!match) return null

    const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])))
    return Number.isNaN(date.getTime()) ? null : date
  }

  spell(date) {
    return date.toLocaleDateString("en", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" })
  }
}
