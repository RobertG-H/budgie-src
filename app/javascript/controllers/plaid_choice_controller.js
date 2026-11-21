import { Controller } from "@hotwired/stimulus"

// One account on the page after Plaid Link (app/views/plaid_choices/_choice.html.erb): its "Becomes" select, and under it the fields for what
// it becomes, a new Account's name and date to read from, a linked Account's date to read from, or a note for one that's left out. Only the
// chosen one's are shown: an option's value is "new", "leave" or "link:<id>", and a panel's data-becomes is "new", "link" or "leave". Choosing
// an Account to link onto starts its date at the option's data-read-from, that Account's latest bank transaction's date; the page as it's drawn
// keeps the date it was drawn with, so a form that comes back keeps what was entered. An Account can be linked onto by one row only, so every
// row's select has the Accounts other rows have chosen disabled (the server refuses it too). Without JavaScript every one shows, and the server
// reads only the chosen one's.
export default class extends Controller {
  static targets = [ "becomes", "panel", "linkDate" ]

  connect() {
    this.toggle()
    this.disableTaken()
  }

  choose() {
    const readFrom = this.becomesTarget.selectedOptions[0]?.dataset.readFrom
    if (readFrom && this.hasLinkDateTarget) this.linkDateTarget.value = readFrom

    this.toggle()
    this.disableTaken()
  }

  toggle() {
    const becomes = this.becomesTarget.value.split(":")[0]

    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.becomes !== becomes
    })
  }

  // Every row's select, in the same form, with each Account another row has chosen disabled in it.
  disableTaken() {
    const form = this.element.closest("form")
    if (!form) return

    const selects = [ ...form.querySelectorAll("select[data-plaid-choice-target='becomes']") ]
    selects.forEach((select) => {
      const takenElsewhere = new Set(selects.filter((other) => other !== select).map((other) => other.value).filter((value) => value.startsWith("link:")))
      select.querySelectorAll("option[value^='link:']").forEach((option) => {
        // Never the row's own choice: a disabled option isn't sent, so a form that came back with the same Account on two rows keeps both, as the error says.
        option.disabled = takenElsewhere.has(option.value) && !option.selected
      })
    })
  }
}
