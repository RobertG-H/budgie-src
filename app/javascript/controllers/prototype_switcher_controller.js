import { Controller } from "@hotwired/stimulus"

// PROTOTYPE (#148), throwaway: the floating bar that switches the Connect a bank prototype's variant and
// screen. ← and → cycle the variant, except while typing in a field.
export default class extends Controller {
  static values = { variants: Array, variant: String, screen: String, base: String }

  connect() {
    this.keydown = this.keydown.bind(this)
    document.addEventListener("keydown", this.keydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.keydown)
  }

  previous() { this.step(-1) }
  next() { this.step(1) }

  screen(event) {
    this.go(this.variantValue, event.target.value)
  }

  step(by) {
    const variants = this.variantsValue
    const index = (variants.indexOf(this.variantValue) + by + variants.length) % variants.length
    this.go(variants[index], this.screenValue)
  }

  go(variant, screen) {
    window.Turbo.visit(`${this.baseValue}/${screen}?variant=${variant}`, { action: "replace" })
  }

  keydown(event) {
    const target = event.target
    if (target.closest("input, textarea, select, [contenteditable]")) return
    if (event.key === "ArrowLeft") this.previous()
    if (event.key === "ArrowRight") this.next()
  }
}
