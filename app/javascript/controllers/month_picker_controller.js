import { Controller } from "@hotwired/stimulus"

// The month picker on the month view (app/views/components/_month_picker.html.erb): a year stepper and a grid of the year's
// twelve months, in a native <dialog> that the modal controller opens, between the years a date field takes (the server says which). The server draws the viewed year; this redraws the grid
// for another one, which is rewriting each link's href, name and marks. Choosing a month is ordinary navigation (Turbo Drive).
//
// The grid is one tab stop (roving tabindex): Left and Right move a month, Up and Down three, Home and End to January and
// December, PageUp and PageDown a year. None of them wraps over the edge of a year, since a year is a step of its own. Space
// follows a link too, which it doesn't natively. Esc closes the dialog and gives focus back to the button that opened it, both
// natively.
const MONTHS = [ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" ]
const COLUMNS = 3

export default class extends Controller {
  static targets = [ "trigger", "name", "dialog", "year", "previousYear", "nextYear", "grid", "month" ]
  static values = { year: Number, month: Number, currentYear: Number, currentMonth: Number, href: String, minYear: Number, maxYear: Number }

  connect() {
    this.shown = this.yearValue
    this.active = this.monthValue - 1
    this.sync()
  }

  // Shows the button in place of the name, which is all a page without JavaScript has. A morph (saving an Assigned amount
  // refreshes the page in place) puts the server's markup back, so this runs again after one.
  sync() {
    this.triggerTarget.hidden = false
    this.nameTarget.hidden = true
  }

  // Runs after the modal controller has opened the dialog, which focused its first button: start on the viewed month's year,
  // with the viewed month focused.
  open() {
    this.active = this.monthValue - 1
    this.show(this.yearValue)
    this.focusMonth(this.active)
  }

  previousYear() {
    this.step(-1)
  }

  nextYear() {
    this.step(1)
  }

  // A typed year is clamped to the range a date field takes, and one that isn't a number goes back to the year being shown.
  yearChanged(event) {
    event.preventDefault()

    const year = parseInt(this.yearTarget.value, 10)

    this.show(Number.isNaN(year) ? this.shown : this.clamp(year))
  }

  navigate(event) {
    if (event.altKey || event.ctrlKey || event.metaKey) return

    const index = this.monthTargets.indexOf(event.target.closest("a"))
    if (index < 0) return

    const moves = { ArrowLeft: index - 1, ArrowRight: index + 1, ArrowUp: index - COLUMNS, ArrowDown: index + COLUMNS, Home: 0, End: 11 }

    if (event.key in moves) {
      event.preventDefault()
      const target = moves[event.key]
      if (target >= 0 && target < 12) this.focusMonth(target)
    } else if (event.key === "PageUp" || event.key === "PageDown") {
      event.preventDefault()
      this.step(event.key === "PageUp" ? -1 : 1, index)
    } else if (event.key === " ") {
      event.preventDefault()
      this.monthTargets[index].click()
    }
  }

  // Going to a month closes the dialog, so choosing the month already being viewed, which Turbo answers by refreshing the
  // page in place, doesn't leave it open over the page.
  // A click with a modifier opens the link somewhere else, such as a new tab, and leaves this one as it was.
  choose(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    if (event.target.closest("a") && this.dialogTarget.open) this.dialogTarget.close()
  }

  step(delta, focusIndex = null) {
    const year = this.shown + delta
    if (year < this.minYearValue || year > this.maxYearValue) return

    this.show(year)
    if (focusIndex !== null) this.focusMonth(focusIndex)
  }

  clamp(year) {
    return Math.min(Math.max(year, this.minYearValue), this.maxYearValue)
  }

  // Draws the grid for a year. The tab stop stays on the same month of the new year.
  show(year) {
    this.shown = year
    this.yearTarget.value = year
    this.gridTarget.setAttribute("aria-label", `Months of ${String(year).padStart(4, "0")}`)
    this.previousYearTarget.disabled = year <= this.minYearValue
    this.nextYearTarget.disabled = year >= this.maxYearValue

    this.monthTargets.forEach((link, index) => {
      const month = index + 1
      const viewed = year === this.yearValue && month === this.monthValue
      const current = year === this.currentYearValue && month === this.currentMonthValue
      const digits = String(year).padStart(4, "0") // as the address and the server's names spell it: 0001, 2026, 10000
      const name = `${MONTHS[index]} ${digits}`

      if (this.hrefValue.includes("{month}")) {
        link.href = this.hrefValue.replace("{month}", `${digits}-${String(month).padStart(2, "0")}`)
      }
      link.setAttribute("aria-label", current ? `${name}, this month` : name)
      if (viewed) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current")
      link.classList.toggle("btn-primary", viewed)
      link.classList.toggle("btn-outline", current && !viewed)
    })

    this.setTabStop(this.active)
  }

  focusMonth(index) {
    this.active = index
    this.setTabStop(index)
    this.monthTargets[index].focus()
  }

  setTabStop(index) {
    this.monthTargets.forEach((link, i) => link.setAttribute("tabindex", i === index ? "0" : "-1"))
  }
}
