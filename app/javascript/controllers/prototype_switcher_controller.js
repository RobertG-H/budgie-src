import { Controller } from "@hotwired/stimulus"

// PROTOTYPE (wayfinder ticket #90): left and right arrow keys cycle the ?variant= links in the floating bar.
export default class extends Controller {
  static targets = [ "prev", "next" ]

  connect() {
    this.onKey = (event) => {
      if (event.target.closest("input, textarea, select, [contenteditable]")) return
      if (event.key === "ArrowLeft") this.prevTarget.click()
      if (event.key === "ArrowRight") this.nextTarget.click()
    }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
  }
}
