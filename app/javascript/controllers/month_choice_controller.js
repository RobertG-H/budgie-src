import { Controller } from "@hotwired/stimulus"

// Keeps a Deposit's "Ready to Assign in" choices in step with its date (see app/views/deposits/_form.html.erb).
// The choices are always the month of the date and the month after it, so when the date changes both are renamed
// and given new values. They're the same two radio buttons throughout, so whichever one was chosen, this month or
// the month after, stays chosen.
export default class extends Controller {
  static targets = [ "date", "radio", "name" ]

  update() {
    const [ year, month ] = this.dateTarget.value.split("-").map(Number)
    if (!year || !month) return // The date was cleared, or isn't whole yet.

    this.radioTargets.forEach((radio, offset) => {
      const first = new Date(0)
      first.setUTCFullYear(year, month - 1 + offset, 1) // Unlike Date.UTC, this doesn't read years 0 to 99 as 19xx.

      const monthNumber = first.getUTCMonth() + 1
      const yearNumber = String(first.getUTCFullYear()).padStart(4, "0")

      radio.value = `${yearNumber}-${String(monthNumber).padStart(2, "0")}-01`
      this.nameTargets[offset].textContent = `${first.toLocaleString("en", { month: "long", timeZone: "UTC" })} ${yearNumber}`
    })
  }
}
