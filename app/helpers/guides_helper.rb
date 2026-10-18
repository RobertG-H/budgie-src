# The User guide's sections, which its list of contents and its headings both read, so the two can't disagree.
module GuidesHelper
  # Each section's id, which is its address on the page (/guide#filing), and its heading, in the order the page has them.
  GUIDE_SECTIONS = {
    "how-it-works" => "How Budgie works",
    "setting-up" => "Setting up",
    "deposits" => "Deposits and Ready to Assign",
    "assigning" => "Assigning money to envelopes",
    "spends-and-refunds" => "Spends and Refunds",
    "reallocations" => "Reallocations",
    "months" => "Month by month",
    "archiving" => "Archiving an envelope",
    "records" => "Records",
    "importing" => "Importing from your bank",
    "filing" => "Filing bank transactions",
    "filing-rules" => "Filing rules and To review",
    "guesses" => "Guesses",
    "splitwise" => "Splitwise",
    "figures" => "What the figures mean"
  }.freeze

  # One section of the guide: its heading, and the block as its text, whose paragraphs and lists are spaced and marked here, once.
  def guide_section(id, &block)
    heading_id = "#{id}-heading"

    tag.section id: id, aria: { labelledby: heading_id }, class: "scroll-mt-4" do
      tag.h2(GUIDE_SECTIONS.fetch(id), id: heading_id, class: "text-lg font-semibold") +
        tag.div(capture(&block), class: "mt-2 space-y-3 [&_ol]:list-decimal [&_ol]:space-y-2 [&_ol]:ps-6 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:ps-6")
    end
  end
end
