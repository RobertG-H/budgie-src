# The header's second row of links, to the pages that aren't a month's, and which of them the page being looked at belongs to.
module SectionsHelper
  # The pages of each section, by path: the section's own and everything under it, so "/records" and "/records/…" but not "/recordsfoo".
  SECTION_PATHS = {
    "Budget" => %r{\A(/|/(months|envelopes)(/.*)?)\z},
    "Records" => %r{\A/records(/.*)?\z},
    "Bank transactions" => %r{\A/(bank_transactions|unfiled)(/.*)?\z},
    "Accounts" => %r{\A/(accounts|imports)(/.*)?\z},
    "Filing rules" => %r{\A/filing_rules(/.*)?\z},
    "CSV formats" => %r{\A/csv_formats(/.*)?\z}
  }.freeze

  # The forms for a Deposit, Spend, Refund or Reallocation. They have no section of their own: they belong to the page they were opened from,
  # as `from` says (ReturnsToOrigin), and go back to a month without one. (An envelope's forms are only ever opened from the month view.)
  RECORD_FORM_PATHS = %r{\A/(deposits|spends|refunds|reallocations)(/.*)?\z}

  # What each page a record was opened from is a part of. `home`, `month`, `deposits` and `envelope` are all the month view's.
  ORIGIN_SECTIONS = {
    "records" => "Records",
    "bank_transactions" => "Bank transactions",
    "account" => "Accounts"
  }.freeze

  # A link to one of the sections in the header. The one being looked at is marked as the current page, in a bolder weight and for
  # assistive technology, and not by colour alone.
  def section_link(name, path)
    current = current_section == name
    link_to name, path, class: [ "link link-hover py-1", ("font-semibold" if current) ], aria: { current: ("page" if current) }
  end

  # The name of the section the page being looked at belongs to, or nil when it's none of them. This is the one place that knows every page,
  # so the layout doesn't repeat it. Import isn't a section, it's a button, so a page it leads to marks the section that page belongs to:
  # an Import belongs to an Account. Worked out once, however many links ask.
  def current_section
    return @current_section if defined?(@current_section)

    path = request.path
    @current_section = SECTION_PATHS.find { |_name, pattern| pattern.match?(path) }&.first
    @current_section ||= ORIGIN_SECTIONS.fetch(params[:from].to_s, "Budget") if RECORD_FORM_PATHS.match?(path)
    @current_section
  end

  # What the count of unfiled bank transactions says, which is capped: counting stops a little past the cap, so "99+" is as exact as it gets.
  def unfiled_count_text(count)
    "#{count > Current::UNFILED_COUNT_CAP ? "#{Current::UNFILED_COUNT_CAP}+" : count} unfiled"
  end
end
