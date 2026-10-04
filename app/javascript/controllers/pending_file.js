// The file chosen for an Import from the header, kept in memory while Turbo renders what comes back. A file isn't kept by the server, so a form
// that comes back from a guess can't contain it: the import-file controller puts it back in the form's file field when it connects. It's module
// state, which outlives the page's controllers, since Turbo replaces the whole <body> and the header's controller goes with it.
let kept = null

export function keep(file) {
  kept = file
}

// The file that was kept, once: it's forgotten as it's taken, so it can't turn up in a form it wasn't meant for.
export function take() {
  const file = kept
  kept = null
  return file
}
