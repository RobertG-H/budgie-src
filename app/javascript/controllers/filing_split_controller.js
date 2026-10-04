import { Controller } from "@hotwired/stimulus"

// The records a bank transaction is filed as (app/views/bank_transaction_filings/_form.html.erb), which can be split into several,
// such as $60 from Groceries and $40 from Household. It adds a record from the template and removes one, numbers the records
// and says what they add up to, against the bank transaction's amount, as they change. That's only to help: the server decides
// whether they add up, and says so in the same words. The records are `filing[records][N]`, and a record added here is numbered
// by the time, so it comes after every one before it and the server reads them in order.
export default class extends Controller {
  static targets = [ "records", "template", "record", "legend", "remove", "add", "total" ]
  static values = { amount: String, unit: String, max: Number }

  connect() {
    this.update()
  }

  // Adds a record that starts with what's left to file, if there's any, and goes to it.
  add() {
    if (this.recordTargets.length >= this.maxValue) return

    this.recordsTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("NEW_RECORD", Date.now()))
    const added = this.recordTargets.at(-1)

    const remaining = this.amountCents() - this.totalCents()
    if (remaining > 0) added.querySelector("[name$='[amount]']").value = (remaining / 100).toFixed(2)

    this.update()
    added.querySelector("select, input:not([type=hidden])")?.focus()
  }

  // Takes a record out, unless it's the only one, which a bank transaction needs at least.
  remove(event) {
    if (this.recordTargets.length <= 1) return

    event.target.closest("[data-filing-split-target=record]").remove()
    this.update()
  }

  // Numbers the records, which only have a heading and a way to remove one when there's more than one, and says what they add up
  // to.
  update() {
    const single = this.recordTargets.length === 1

    this.legendTargets.forEach((legend, index) => {
      legend.textContent = `Record ${index + 1}`
      legend.hidden = single
    })
    this.removeTargets.forEach((remove) => { remove.hidden = single })
    this.addTarget.disabled = this.recordTargets.length >= this.maxValue

    const remaining = this.amountCents() - this.totalCents()
    const amount = this.money(this.amountCents())
    const total = this.money(this.totalCents())

    if (remaining === 0) {
      this.totalTarget.textContent = `Adds up to ${total} of ${amount}.`
    } else if (remaining > 0) {
      this.totalTarget.textContent = `Adds up to ${total} of ${amount}, with ${this.money(remaining)} left.`
    } else {
      this.totalTarget.textContent = `Adds up to ${total} of ${amount}, which is ${this.money(-remaining)} over.`
    }

    this.totalTarget.classList.toggle("text-error", remaining < 0)
    this.totalTarget.classList.toggle("text-base-content/70", remaining >= 0)
  }

  // In whole cents, so that adding amounts doesn't drift. An amount that isn't a number counts as nothing.
  amountCents() {
    return this.cents(this.amountValue)
  }

  totalCents() {
    return Array.from(this.element.querySelectorAll("[data-filing-split-target=record] [name$='[amount]']"))
      .reduce((sum, input) => sum + this.cents(input.value), 0)
  }

  cents(value) {
    const cents = Math.round(parseFloat(value) * 100)
    return Number.isNaN(cents) ? 0 : cents
  }

  money(cents) {
    const figure = (Math.abs(cents) / 100).toLocaleString("en", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    return `${cents < 0 ? "-" : ""}${this.unitValue}${figure}`
  }
}
