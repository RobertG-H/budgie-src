import { Controller } from "@hotwired/stimulus"

// The header's menu (app/views/layouts/_menu.html.erb), a native <details> that opens and closes by itself. This only closes it
// where a menu is expected to close and <details> doesn't: on a click outside it, on Escape, and before Turbo caches the page.
export default class extends Controller {
  static targets = [ "toggle" ]

  close() {
    this.element.open = false
  }

  closeFromOutside(event) {
    if (this.element.open && !this.element.contains(event.target)) this.close()
  }

  // Focus goes back to the button that opened it, when it was inside the menu, so a keyboard doesn't lose its place.
  closeFromKeyboard() {
    if (!this.element.open) return

    const focusWasInside = this.element.contains(document.activeElement)
    this.close()
    if (focusWasInside) this.toggleTarget.focus()
  }
}
