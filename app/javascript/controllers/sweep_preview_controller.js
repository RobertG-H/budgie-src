import { Controller } from "@hotwired/stimulus"

// What saving a Filing rule would do, kept up to date while the rule is edited (app/views/filing_rules/_offer_preview.html.erb): whether it
// updates a rule that's there, and how many unfiled bank transactions it would file or ignore, which a person looks at before ticking the box
// that does it. It's the form's own fields for the rule, the ones whose names start with `scope`, sent to `url` after a pause, and the frame
// that answers is the one that holds the box, so the server decides what the numbers are and there's no matching written in JavaScript.
// The box is sent along, so that it stays as it was ticked. Without JavaScript the numbers are the ones the form started with.
export default class extends Controller {
  static targets = [ "frame" ]
  static values = { url: String, scope: String, delay: { type: Number, default: 300 } }

  // The frame's own box doesn't change what the numbers are.
  update(event) {
    if (event.target.closest("turbo-frame")) return

    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.refresh(), this.delayValue)
  }

  refresh() {
    const params = new URLSearchParams()
    for (const [ name, value ] of new FormData(this.element.closest("form"))) {
      if (name.startsWith(`${this.scopeValue}[`)) params.append(name, value)
    }

    this.frameTarget.src = `${this.urlValue}?${params}`
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
