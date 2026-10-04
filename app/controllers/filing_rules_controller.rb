# The Filing rules: standing instructions that file or ignore the bank transactions that come in, the same way each time (ADR 0012). Every
# rule is listed here, grouped by what it sets, and a rule can be made from scratch, edited and deleted. Editing or deleting one never changes
# what it already filed or ignored (ADR 0002): it only affects what comes in from then on, and saving it can also sweep the unfiled bank
# transactions that are already there.
class FilingRulesController < ApplicationController
  # A heading and the rules under it: an envelope's name for the ones that go to it, then Deposit, then Ignore.
  Section = Data.define(:title, :envelope, :rules)

  before_action :set_filing_rule, only: %i[ edit update destroy ]

  # Each rule with how many bank transactions it filed or ignored, which is only those that still are: one that was un-filed since isn't
  # counted. The query count doesn't grow with the rules.
  def index
    rules = Current.budget.filing_rules.includes(:account, :envelope).alphabetical_by_text.to_a
    @counts = Budget::BankTransaction.filed_or_ignored.where(filing_rule_id: rules.map(&:id)).group(:filing_rule_id).count(:id)
    @sections = sections_of(rules)
  end

  def new
    @filing_rule = Current.budget.filing_rules.new(outcome: "spend")
  end

  # Saves the rule, and sweeps if the box was ticked, in one database transaction: when it fails, nothing is done.
  def create
    @filing_rule = Current.budget.filing_rules.new(filing_rule_params)

    if @filing_rule.save_and_sweep(sweep: sweep?)
      redirect_to filing_rules_path, notice: notice_with_sweep("Filing rule added.")
    else
      render :new, status: :unprocessable_content
    end
  end

  # What it would do to the unfiled bank transactions as it stands is what the box offers to file or ignore.
  def edit
    @sweep = Budget::FilingRule::Sweep.new(@filing_rule)
  end

  def update
    @filing_rule.assign_attributes(filing_rule_params)

    if @filing_rule.save_and_sweep(sweep: sweep?)
      redirect_to filing_rules_path, notice: notice_with_sweep("Filing rule updated.")
    else
      render :edit, status: :unprocessable_content
    end
  end

  # What it filed or ignored stays as it is, only with no rule to say which one did it.
  def destroy
    @filing_rule.destroy!
    redirect_to filing_rules_path, status: :see_other, notice: "Filing rule deleted."
  end

  private
    # Found through the user's budget, so another user's rule is a 404.
    def set_filing_rule
      @filing_rule = Current.budget.filing_rules.includes(:account, :envelope).find(params[:id])
    end

    # Never the budget it belongs to. The Account and the envelope are looked up by the model, which refuses another budget's.
    def filing_rule_params
      entered_filing_rule.except(:sweep)
    end

    # Whether the box that files or ignores the unfiled bank transactions the rule fits was ticked.
    def sweep?
      entered_filing_rule[:sweep] == "1"
    end

    def entered_filing_rule
      @entered_filing_rule ||= params.expect(filing_rule: [ :text, :account_id, :amount, :outcome, :envelope_id, :sweep ])
    end

    # What's said once it's saved, with what the sweep did, if it did anything: "Filing rule added. It also filed 2 bank transactions." A rule
    # has one outcome, so a sweep files or ignores, and never both.
    def notice_with_sweep(notice)
      swept = @filing_rule.swept
      return notice if swept.nil? || swept.none?

      "#{notice} It also #{swept.describe("bank transaction")}."
    end

    # One section for each envelope that has a rule, alphabetically as in the month view, then Deposit, then Ignore, each only if it has any.
    def sections_of(rules)
      to_envelopes, others = rules.partition(&:needs_envelope?)
      envelope_sections = to_envelopes.group_by(&:envelope).sort_by { |envelope, _| [ envelope.name.downcase, envelope.id ] }
        .map { |envelope, group| Section.new(title: envelope.name, envelope: envelope, rules: group) }
      other_sections = others.group_by(&:outcome).slice("deposit", "ignore").map { |outcome, group| Section.new(title: outcome.capitalize, envelope: nil, rules: group) }

      envelope_sections + other_sections
    end
end
