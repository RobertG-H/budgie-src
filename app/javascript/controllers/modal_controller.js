import { Controller } from "@hotwired/stimulus"

// Opens a native <dialog> (see app/views/components/_modal.html.erb). The browser handles Esc, focus and
// the inert page behind it, and a <form method="dialog"> inside closes it.
export default class extends Controller {
  static targets = [ "dialog" ]

  open() {
    this.dialogTarget.showModal()
  }

  // The dialog fills the viewport, so a click that lands on the dialog itself is a click on the backdrop.
  closeOnBackdrop(event) {
    if (event.target === this.dialogTarget) this.dialogTarget.close()
  }

  // Turbo caches a snapshot of the page when leaving it, so don't leave the dialog open in the cache.
  disconnect() {
    this.dialogTarget.close()
  }
}
