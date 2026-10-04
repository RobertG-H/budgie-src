import { Controller } from "@hotwired/stimulus"

// The CSV format builder (app/views/csv_formats/_form.html.erb). It keeps the sample's grid and the preview up to date as the
// choices change, by sending the form to the preview, which answers with both. It also shows only the columns that the chosen
// amount style uses. Without JavaScript every column shows, and the Preview button does the same thing a page at a time.
export default class extends Controller {
  static targets = [ "previewActions", "previewButton", "amountStyle", "styleGroup" ]
  static values = { delay: { type: Number, default: 400 } }

  connect() {
    this.previewActionsTarget.hidden = true // The preview is live, so there's nothing to press.
    this.toggleStyle()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  // Previews once the choices have stopped changing, so typing a column number isn't a request for every key.
  schedule() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.preview(), this.delayValue)
  }

  preview() {
    clearTimeout(this.timer)
    this.element.requestSubmit(this.previewButtonTarget)
  }

  // Each group of fields says which amount styles use it, and is shown only for the one that's chosen.
  toggleStyle() {
    const style = this.amountStyleTargets.find((radio) => radio.checked)?.value

    this.styleGroupTargets.forEach((group) => {
      group.hidden = !group.dataset.styles.split(" ").includes(style)
    })
  }
}
