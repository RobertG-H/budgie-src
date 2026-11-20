import { Controller } from "@hotwired/stimulus"

// Opens Plaid Link on the Connect a bank page, and on a bank's Reconnect and Choose accounts pages (app/views/plaid_connections/_link.html.erb), with the
// link token the server made as it rendered.
// Plaid's script (link-initialize.js, which must come from cdn.plaid.com) is in the page's <head>, and Turbo appends a new head script on a
// visit without waiting for it to load, so this waits for window.Plaid before it calls Plaid.create, and destroys the handler, which removes
// Link's iframe, when it disconnects.
//
// When the person finishes, Link gives a public token and the bank and accounts they shared. They go into the ordinary form's hidden fields
// and the form is submitted, so Turbo sends them with the CSRF token and follows the redirect to the page where each account's choice is made.
// The server trusts them only to skip an exchange. `mode` says how much of it is sent: all of it to connect ("connect"), only the accounts now
// shared for Choose accounts ("choose"), and nothing for Reconnect ("reconnect"), since update mode keeps the Item and has nothing to exchange. Leaving Link changes nothing, except a link token Plaid no longer accepts, which reloads
// the page for a new one.
export default class extends Controller {
  static targets = [ "button", "form", "fields", "unavailable" ]
  static values = { token: String, mode: { type: String, default: "connect" } }

  // How long to wait for Plaid's script before saying it couldn't be loaded, in milliseconds.
  static WAIT = 20000
  static STEP = 50

  connect() {
    this.stopped = false
    this.waitForPlaid().then((Plaid) => {
      if (this.stopped || this.handler) return

      if (!Plaid) {
        this.unavailableTarget.hidden = false
        return
      }

      this.handler = Plaid.create({
        token: this.tokenValue,
        onSuccess: (publicToken, metadata) => this.succeeded(publicToken, metadata),
        onExit: (error) => this.exited(error)
      })
      this.buttonTarget.disabled = false
    })
  }

  disconnect() {
    this.stopped = true
    this.handler?.destroy()
    this.handler = null
  }

  open(event) {
    event.preventDefault()
    this.handler?.open()
  }

  succeeded(publicToken, metadata) {
    this.fieldsTarget.replaceChildren()
    if (this.modeValue === "connect") {
      this.add("plaid_link[public_token]", publicToken)
      this.add("plaid_link[institution_id]", metadata.institution?.institution_id)
      this.add("plaid_link[institution_name]", metadata.institution?.name)
    }
    if (this.modeValue !== "reconnect") this.addAccounts(metadata.accounts || [])

    this.buttonTarget.disabled = true
    this.formTarget.requestSubmit()
  }

  addAccounts(accounts) {
    accounts.forEach((account, index) => {
      this.add(`plaid_link[accounts][${index}][id]`, account.id)
      this.add(`plaid_link[accounts][${index}][name]`, account.name)
      this.add(`plaid_link[accounts][${index}][mask]`, account.mask)
      this.add(`plaid_link[accounts][${index}][subtype]`, account.subtype)
    })
  }

  exited(error) {
    if (error?.error_code === "INVALID_LINK_TOKEN") window.location.reload()
  }

  add(name, value) {
    if (value === null || value === undefined) return

    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    this.fieldsTarget.append(input)
  }

  // Resolves with window.Plaid once it's there, or with nothing when it doesn't come or the page has gone.
  waitForPlaid() {
    return new Promise((resolve) => {
      let waited = 0
      const check = () => {
        if (window.Plaid) return resolve(window.Plaid)
        if (this.stopped || waited >= this.constructor.WAIT) return resolve(null)

        waited += this.constructor.STEP
        setTimeout(check, this.constructor.STEP)
      }
      check()
    })
  }
}
