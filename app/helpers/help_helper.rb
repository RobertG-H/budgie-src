# The words that need explaining, and the one sentence for each (`help:` in config/locales/en.yml). A tooltip and the page's own words both
# read them through here, so the two say the same.
module HelpHelper
  # Each key of `help:` that is a word of the app, and what the page calls it.
  TERMS = {
    ready_to_assign: "Ready to Assign",
    assigned: "Assigned",
    carried_over: "Carried over",
    reallocated: "Reallocated",
    reallocate: "Reallocate",
    archive: "Archive",
    available: "Available"
  }.freeze

  # What the page calls a term, such as "Carried over". A key that isn't a term is an error, not a blank.
  def help_term(key)
    TERMS.fetch(key.to_sym)
  end

  # The sentence under a `help:` key, such as what a term means. A key with none is an error, not a blank.
  def help_text(key)
    I18n.t!("help.#{key}")
  end

  # The id of the element that holds a term's sentence, which the term is described by. Hyphens, since a key's underscores are never in markup.
  def help_id(key)
    help_term(key)
    "help-#{key.to_s.dasherize}"
  end
end
