import { Controller } from "@hotwired/stimulus"

// PROTOTYPE (wayfinder ticket #90). "Show details" for the month view's Carried over, Refunded and Reallocated.
// The state is an attribute on <html>, outside <body>, so Turbo's morph refresh (saving an Assigned amount) can't
// reset it, and it's remembered per browser in localStorage. Every piece of markup reads it with Tailwind's
// in-data-[details=on]: variant, so this controller only flips the attribute and keeps aria-pressed in step.
const KEY = "budgie.monthDetails"

export default class extends Controller {
  static targets = [ "button" ]

  connect() {
    let saved = null
    try { saved = localStorage.getItem(KEY) } catch (_) {}
    if (saved) document.documentElement.dataset.details = saved
    this.sync = this.sync.bind(this)
    document.addEventListener("turbo:morph", this.sync)
    this.sync()
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.sync)
  }

  toggle() {
    this.set(document.documentElement.dataset.details === "on" ? "off" : "on")
  }

  choose(event) {
    this.set(event.params.value)
  }

  set(value) {
    document.documentElement.dataset.details = value
    try { localStorage.setItem(KEY, value) } catch (_) {}
    this.sync()
  }

  sync() {
    const on = document.documentElement.dataset.details === "on"
    this.buttonTargets.forEach((button) => {
      if (button.type === "checkbox") button.checked = on
      else if (button.dataset.value) button.setAttribute("aria-pressed", String((button.dataset.value === "on") === on))
      else button.setAttribute("aria-pressed", String(on))
    })
  }
}
