import { Controller } from "@hotwired/stimulus"

// "Show details" on the month view: whether Carried over, Refunded and Reallocated are shown. Whether they are is
// data-details="on|off" on <html>, which is outside the <body> Turbo morphs, so saving an Assigned amount can't reset
// it, and every piece of markup reads it with Tailwind's in-data-[details=on]: variant. It's remembered per browser in
// localStorage, which the page works without, and the layout's <head> applies it before the first paint with the same key.
// This only flips the attribute and keeps aria-pressed in step, which a morph resets.
const KEY = "budgie.monthDetails"

export default class extends Controller {
  static targets = [ "button" ]

  connect() {
    this.sync()
  }

  toggle() {
    const value = this.on ? "off" : "on"

    document.documentElement.dataset.details = value
    try { localStorage.setItem(KEY, value) } catch (_) {}
    this.sync()
  }

  sync() {
    this.buttonTargets.forEach((button) => button.setAttribute("aria-pressed", String(this.on)))
  }

  get on() {
    return document.documentElement.dataset.details === "on"
  }
}
