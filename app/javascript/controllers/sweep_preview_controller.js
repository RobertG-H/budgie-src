import { Controller } from "@hotwired/stimulus"

// What saving a Filing rule would do, kept up to date while the rule is edited (app/views/filing_rules/_offer_preview.html.erb): whether it
// updates a rule that's there, and how many unfiled bank transactions it would file or ignore, which a person looks at before ticking the box
// that does it. It's the form's own fields for the rule, the ones whose names start with `scope`, sent to `url` after a pause, and the frame
// that answers is the one that holds the box, so the server decides what the numbers are and there's no matching written in JavaScript.
// The box is sent along, so that it stays as it was ticked. Without JavaScript the numbers are the ones the form started with. A sentence that
// says the rule's text, as the filing form's does under "Always file like this", marks it as an `echo`, which is kept as the text is edited,
// normalised as a rule keeps it: trimmed, its spaces collapsed and in lower case.
export default class extends Controller {
  static targets = [ "frame", "echo" ]
  static values = { url: String, scope: String, delay: { type: Number, default: 300 } }

  // The frame's own box doesn't change what the numbers are.
  update(event) {
    if (event.target.closest("turbo-frame")) return

    if (event.target.name === `${this.scopeValue}[text]`) this.echo(event.target.value)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.refresh(), this.delayValue)
  }

  echo(text) {
    const normalized = text.trim().replace(/\s+/g, " ").toLowerCase()
    this.echoTargets.forEach((target) => { target.textContent = normalized })
  }

  refresh() {
    const url = new URL(this.urlValue, window.location.origin)
    for (const [ name, value ] of new FormData(this.element.closest("form"))) {
      if (name.startsWith(`${this.scopeValue}[`)) url.searchParams.append(name, value)
    }

    this.frameTarget.src = url.pathname + url.search
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
