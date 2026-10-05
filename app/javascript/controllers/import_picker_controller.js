import { Controller } from "@hotwired/stimulus"
import { keep } from "controllers/pending_file"

// "Import" in the header (app/views/layouts/_import_button.html.erb). The button is a link to the whole Import form, which works without
// JavaScript; this makes it open the file chooser at once instead, and when a file is chosen, send it to be guessed (POST /imports/guess): Budgie
// works out the CSV format and the Account, and imports it straight away only when both are certain. It's only attached when the budget has at
// least one CSV format and one Account, so a person who has neither lands on the page that says what's missing.
export default class extends Controller {
  static targets = [ "form", "input" ]

  // Opens the chooser, with nothing chosen, so choosing the same file twice still sends it.
  choose(event) {
    event.preventDefault()
    this.inputTarget.value = ""
    this.inputTarget.click()
  }

  // Sends the file that was chosen, and keeps it for the form that may come back, which can't contain it (the server doesn't keep a file).
  send() {
    const file = this.inputTarget.files[0]
    if (!file) return

    keep(file)
    this.formTarget.requestSubmit()
  }
}
