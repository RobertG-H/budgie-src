import { Controller } from "@hotwired/stimulus"

// One account on the page after Plaid Link (app/views/plaid_choices/_choice.html.erb): its "Becomes" select, and under it the fields for what
// it becomes, a new Account's name and date to read from, or a note for one that's left out. Only the chosen one's are shown. Without
// JavaScript every one shows, and the server reads only the chosen one's.
export default class extends Controller {
  static targets = [ "becomes", "panel" ]

  connect() {
    this.toggle()
  }

  toggle() {
    const becomes = this.becomesTarget.value

    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.becomes !== becomes
    })
  }
}
