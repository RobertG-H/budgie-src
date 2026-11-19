import { Controller } from "@hotwired/stimulus"

// PROTOTYPE (#148), throwaway: one shared account on the choice page after Link. Shows the fields for what
// it becomes (new, link or leave), and starts a linked one's date at the chosen Account's latest row.
// The choice is a checked radio with data-choice, or a select with data-choice whose values are
// "new", "link:<key>" or "leave". A linked Account's options carry data-latest and data-latest-text.
export default class extends Controller {
  static targets = [ "panel", "date", "day" ]

  connect() { this.update() }

  update() {
    const mode = this.mode()
    this.panelTargets.forEach(panel => { panel.hidden = !panel.dataset.for.split(" ").includes(mode) })
    this.element.dataset.mode = mode

    const option = this.element.querySelector("select[data-choice] option:checked, select[data-link-target] option:checked")
    if (mode === "link" && option?.dataset.latest) {
      this.dateTargets.forEach(input => { if (input.closest("[data-for]")?.dataset.for.includes("link")) input.value = option.dataset.latest })
      this.dayTargets.forEach(span => { span.textContent = option.dataset.latestText })
    }
  }

  mode() {
    const include = this.element.querySelector("input[type=checkbox][data-include]")
    if (include && !include.checked) return "leave"
    const radio = this.element.querySelector("input[type=radio][data-choice]:checked")
    if (radio) return radio.value
    const select = this.element.querySelector("select[data-choice]")
    return select ? select.value.split(":")[0] : "new"
  }
}
