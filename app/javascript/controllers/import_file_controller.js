import { Controller } from "@hotwired/stimulus"
import { take } from "controllers/pending_file"

// The Import form that comes back from a guess that wasn't certain: the file isn't kept, so the field is empty, and this puts the file the person
// chose back in it, so they see it already chosen. It only does so for a form that came back from a guess, which is the one with the words
// "Choose the file again." as a target; when it can't (a browser without DataTransfer), the field stays empty and the words stay, and nothing else
// is lost.
export default class extends Controller {
  static targets = [ "input", "again" ]

  connect() {
    if (!this.hasAgainTarget) return

    const file = take()
    if (!file || typeof DataTransfer === "undefined") return

    try {
      const transfer = new DataTransfer()
      transfer.items.add(file)
      this.inputTarget.files = transfer.files
      this.againTargets.forEach((element) => element.remove())
    } catch (_) {
      // The field stays empty, and says so.
    }
  }
}
