import { Controller } from "@hotwired/stimulus"

// One record that a bank transaction is filed as (app/views/bank_transaction_filings/_record.html.erb). Which fields it has depends
// on its kind: a Deposit counts toward a month and has no envelope, and a Refund or a Spend is in an envelope. Each group of fields
// says which kinds have it, and is shown only for the one that's chosen. Money out has one kind and nothing to choose, so it's a
// hidden field. Without JavaScript every group shows, and the server leaves out what a kind doesn't have.
export default class extends Controller {
  static targets = [ "kind", "group" ]

  connect() {
    this.toggle()
  }

  toggle() {
    const chosen = this.kindTargets.find((kind) => kind.type === "hidden" || kind.checked)
    const kind = chosen?.value

    this.groupTargets.forEach((group) => {
      group.hidden = !group.dataset.kinds.split(" ").includes(kind)
    })
  }
}
