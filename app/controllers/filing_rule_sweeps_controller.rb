# What a Filing rule would do to the unfiled bank transactions that are already there if it were saved as it's entered: how many it would
# file or ignore, with the box that does it. It's a Turbo Frame that the Filing rules page's forms ask for, with the form's own fields, as
# they're edited, so that a rule that's too broad is seen before it's saved (ADR 0012). Nothing is changed, and a rule that isn't valid yet
# has no count to give.
class FilingRuleSweepsController < ApplicationController
  def show
    rule = params[:id].present? ? Current.budget.filing_rules.find(params[:id]) : Current.budget.filing_rules.new
    entered = params.slice(:filing_rule).permit(filing_rule: [ :text, :account_id, :amount, :outcome, :envelope_id, :sweep ]).fetch(:filing_rule, {})
    rule.assign_attributes(entered.except(:sweep))

    @sweep = Budget::FilingRule::Sweep.new(rule) if rule.valid?
    @checked = entered[:sweep] != "0"
  end
end
