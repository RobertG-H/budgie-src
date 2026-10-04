# What the filing form sends, for the controllers that read it: filing, and ignoring, which sends the same form. It's a form of records,
# as a bank transaction can be split, and the Filing rule that "Always file like this" makes from what's done.
module FilingFormParams
  extend ActiveSupport::Concern

  RECORD_FIELDS = %i[ kind envelope_id description date month amount notes ].freeze

  private
    # The records the form sent, in the order it numbered them, as drafts. A form sends its records as a hash from each one's number,
    # such as `records[0][kind]`. The kind, the envelope and the rest are only what's asked: Filing looks the envelope up in the
    # budget's own, and refuses what isn't right.
    def draft_params
      records = params.expect(filing: [ records: [ RECORD_FIELDS ] ])[:records]

      drafts_in(records)
    end

    # The same, from a form that needn't have sent any, such as Ignore's, which doesn't read them: it only needs them to show the form
    # as it was if the rule is refused.
    def submitted_drafts
      records = params.permit(filing: { records: RECORD_FIELDS }).dig(:filing, :records)

      records ? drafts_in(records) : [ Budget::Filing::Draft.for(@bank_transaction) ]
    end

    def drafts_in(records)
      records.to_h.sort_by { |number, _| number.to_i }.map { |_, record| Budget::Filing::Draft.new(record) }
    end

    # The rule the form offers to make, as it was sent, or as it starts when `sent` is false: ticked, with the bank's description. A
    # form that didn't send the box leaves it unticked, which is no rule, and a form of more than one record is never a rule.
    def filing_rule_offer(sent: true, records: 1)
      rule = params.permit(filing: { rule: [ :make, :text, :sweep ] }).dig(:filing, :rule) if sent

      Budget::FilingRule::Offer.new(@bank_transaction, budget: Current.budget, split: records > 1,
        make: (sent ? rule&.dig(:make) : true), text: rule&.dig(:text), sweep: (sent ? rule&.dig(:sweep) : true))
    end

    # What's said once it's done, with what the Filing rule's sweep did, if it did anything: "Bank transaction filed. The Filing rule also
    # filed 2 other bank transactions." A rule has one outcome, so a sweep files or ignores, and never both.
    def notice_with_sweep(notice, offer)
      swept = offer.swept
      return notice if swept.nil? || (swept.filed + swept.ignored).zero?

      verb, count = swept.filed.positive? ? [ "filed", swept.filed ] : [ "ignored", swept.ignored ]
      "#{notice} The Filing rule also #{verb} #{helpers.pluralize(count, "other bank transaction")}."
    end
end
