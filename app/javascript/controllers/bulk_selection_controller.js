import { Controller } from "@hotwired/stimulus"

// The bar above a list of bank transactions on the Bank transactions page (app/views/bank_transactions/_bulk_bar.html.erb), for doing one thing to every
// row that's ticked. The page works without this: the rows' checkboxes join the bar's form by their `form` attribute, and each button sends it to its own address.
// With it, the bar can tick every row on the page (a checkbox it reveals) and a range with shift-click, says how many are ticked, disables its buttons while
// none are, names what filing would make ("File 38 Spends and 2 Refunds to Travel", in the words the server uses for its notice), and says how many records
// un-filing would delete when it asks first.
//
// Selection is within the page only: there's no way to choose across pages.

// What was ticked when the page was about to be morphed, kept outside the controller because a morph can replace the element it's on.
let ticked = null

export default class extends Controller {
  static targets = [ "row", "all", "allLabel", "count", "action", "envelope" ]

  connect() {
    this.sync()
  }

  // Reveals select-all (a morph draws it hidden again), ticks again what was ticked before a morph, and brings the bar in step.
  sync() {
    if (!this.hasAllTarget) return

    this.last = null
    this.allLabelTarget.hidden = false
    if (ticked) this.rowTargets.forEach((row) => { row.checked = ticked.has(row.value) })
    ticked = null
    this.update()
  }

  // A row's checkbox was clicked: with shift held, every row between it and the one clicked before takes its state, as in a mail list.
  toggle(event) {
    const index = this.rowTargets.indexOf(event.target)

    if (event.shiftKey && this.last !== null) {
      const [ from, to ] = [ this.last, index ].sort((a, b) => a - b)
      this.rowTargets.slice(from, to + 1).forEach((row) => { row.checked = event.target.checked })
    }

    this.last = index
    this.update()
  }

  toggleAll() {
    this.rowTargets.forEach((row) => { row.checked = this.allTarget.checked })
    this.update()
  }

  // The page is morphed in place when a row's Mark reviewed or Un-file sends it back to the same address, which would untick what's ticked (a morph sets the
  // checked state the server drew), so the ticked rows are remembered before it and ticked again after it.
  remember(event) {
    if (event.detail.renderMethod !== "morph") return

    ticked = new Set(this.rowTargets.filter((row) => row.checked).map((row) => row.value))
  }

  // Once Stimulus has seen the morphed page, which is after the event.
  restore() {
    requestAnimationFrame(() => this.sync())
  }

  update() {
    const ticked = this.rowTargets.filter((row) => row.checked)
    const none = ticked.length === 0

    this.allTarget.checked = !none && ticked.length === this.rowTargets.length
    this.allTarget.indeterminate = !none && ticked.length < this.rowTargets.length
    this.countTarget.textContent = none ? "Tick bank transactions to choose them." : `${ticked.length} selected`

    this.actionTargets.forEach((button) => {
      button.disabled = none
      if (button.dataset.kind === "file") button.textContent = this.fileLabel(ticked)
      if (button.dataset.kind === "unfile") button.dataset.turboConfirm = this.unfileQuestion(ticked)
    })
  }

  // "File 38 Spends and 2 Refunds to Travel": money out is Spends and money in is Refunds, to the envelope chosen once there is one.
  fileLabel(ticked) {
    const spends = ticked.filter((row) => row.dataset.direction === "out").length
    const refunds = ticked.length - spends
    const kinds = [ this.count(spends, "Spend"), this.count(refunds, "Refund") ].filter(Boolean).join(" and ")
    const envelope = this.hasEnvelopeTarget ? this.envelopeTarget.selectedOptions[0] : null
    const to = envelope && envelope.value ? ` to ${envelope.text}` : ""

    return kinds ? `File ${kinds}${to}` : "File selected"
  }

  // What the Un-file button asks: how many bank transactions, and how many records it deletes, which each row says it was filed as.
  unfileQuestion(ticked) {
    const records = ticked.reduce((total, row) => total + Number(row.dataset.records || 0), 0)
    const bankTransactions = this.count(ticked.length, "bank transaction")
    const deletes = records > 0 ? ` This deletes the ${this.count(records, "record")} they were filed as.` : ""

    return ticked.length === 0 ? "Un-file the selected bank transactions?" : `Un-file ${bankTransactions}?${deletes}`
  }

  count(number, noun) {
    return number > 0 ? `${number} ${noun}${number === 1 ? "" : "s"}` : null
  }
}
