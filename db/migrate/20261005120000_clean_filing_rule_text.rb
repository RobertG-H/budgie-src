# A Filing rule's text is read without its numbers and symbols from now on (#117), so a rule saved as "loblaws #1234" is saved as "loblaws".
# Rules that were made before keep their old text until this cleans it, and match as if it were clean in the meantime (`FilingRule#text_for_matching`),
# so none stops fitting.
#
# It never deletes a rule. A rule whose cleaned text is another rule's conditions (the same budget, text, Account and amount, which the unique index
# refuses), such as "loblaws #1" and "loblaws #2", or one that would be left under 3 characters, keeps its old text: it still fits as it did, and
# is for a person to tidy. The most recently edited of rules that would collide takes the cleaned text, which is also the one that wins between them.
#
# The cleaning is a copy of what `Budget::BankTransaction.normalize_for_matching` did when this was written, and not a call to it, so that changing
# that later can't change what this migration does. A rule's `updated_at` is when it was last edited, which breaks ties between rules, so it's left alone.
class CleanFilingRuleText < ActiveRecord::Migration[8.1]
  MIN_TEXT_LENGTH = 3

  class Rule < ActiveRecord::Base
    self.table_name = "budget_filing_rules"
  end

  def up
    rules = Rule.order(updated_at: :desc, id: :desc).to_a
    taken = rules.to_set { |rule| conditions(rule, rule.text) }

    rules.each do |rule|
      cleaned = clean(rule.text)
      next if cleaned == rule.text || cleaned.length < MIN_TEXT_LENGTH

      cleaned_conditions = conditions(rule, cleaned)
      next if taken.include?(cleaned_conditions)

      taken.delete(conditions(rule, rule.text))
      taken.add(cleaned_conditions)
      Rule.where(id: rule.id).update_all(text: cleaned)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "The text a rule had before it was cleaned isn't kept."
  end

  private
    def conditions(rule, text)
      [ rule.budget_id, text, rule.account_id, rule.amount&.to_s("F") ]
    end

    def clean(text)
      words = text.squish.downcase(:fold).sub(%r{/[^\s/]+\z}, "").gsub(%r{[#/*\\_,]}, " ").split.filter_map do |word|
        word = word.gsub(/\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/, "")
        word unless word.length < 2 || !word.match?(/\p{L}/) || word.scan(/\p{N}/).size >= 3
      end

      words.join(" ")
    end
end
