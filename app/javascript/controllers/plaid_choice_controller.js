import { Controller } from "@hotwired/stimulus"

// One account on the page after Plaid Link (app/views/plaid_choices/_choice.html.erb): its "Becomes" select, and under it the fields for what
// it becomes, a new Account's name and date to read from, a linked Account's date to read from, or a note for one that's left out. Only the
// chosen one's are shown: an option's value is "new", "leave" or "link:<id>", and a panel's data-becomes is "new", "link" or "leave". Choosing
// an Account to link onto starts its date at the option's data-read-from, that Account's latest bank transaction's date; the page as it's drawn
// keeps the date it was drawn with, so a form that comes back keeps what was entered. Without JavaScript every one shows, and the server reads
// only the chosen one's.
export default class extends Controller {
  static targets = [ "becomes", "panel", "linkDate" ]

  connect() {
    this.toggle()
  }

  choose() {
    const readFrom = this.becomesTarget.selectedOptions[0]?.dataset.readFrom
    if (readFrom && this.hasLinkDateTarget) this.linkDateTarget.value = readFrom

    this.toggle()
  }

  toggle() {
    const becomes = this.becomesTarget.value.split(":")[0]

    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.becomes !== becomes
    })
  }
}
