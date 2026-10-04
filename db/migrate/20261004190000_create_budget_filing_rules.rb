class CreateBudgetFilingRules < ActiveRecord::Migration[8.1]
  def change
    # A standing instruction, such as "anything from Loblaws goes to Groceries": bank transactions with its text in their
    # description are filed, or ignored, the way it says. It belongs to its budget and never to a user, as Accounts and CSV
    # formats do. Importer tables may have nulls where absence is real: no Account means any Account, no amount any amount.
    create_table :budget_filing_rules do |t|
      t.references :budget, null: false, index: false, foreign_key: { on_delete: :restrict }
      # Stored the way ADR 0010 normalises a description: trimmed, whitespace collapsed, case folded. The model does it, since the
      # database only checks how long it is, so that Ruby and PostgreSQL never disagree over what counts as the same text.
      t.string :text, null: false
      t.references :account, foreign_key: { to_table: :budget_accounts, on_delete: :restrict }
      # Signed, the way a bank transaction's is: money out is negative.
      t.decimal :amount, precision: 15, scale: 2
      # What it does with a bank transaction it fits: spend, refund, deposit or ignore.
      t.string :outcome, null: false
      # Where a Spend or a Refund goes, and nothing for a Deposit or Ignore.
      t.references :envelope, foreign_key: { to_table: :budget_envelopes, on_delete: :restrict }

      t.timestamps
    end

    # Two rules never have identical conditions. Nulls count as the same, so "no Account" twice is the same condition. It also serves
    # finding a budget's rules.
    add_index :budget_filing_rules, [ :budget_id, :text, :account_id, :amount ], unique: true, nulls_not_distinct: true,
      name: "index_budget_filing_rules_on_conditions"
    add_check_constraint :budget_filing_rules, "char_length(btrim(text)) >= 3", name: "budget_filing_rules_text_at_least_3_characters"
    add_check_constraint :budget_filing_rules, "outcome IN ('spend', 'refund', 'deposit', 'ignore')", name: "budget_filing_rules_outcome_known"
    add_check_constraint :budget_filing_rules, "amount IS NULL OR amount <> 0", name: "budget_filing_rules_amount_not_zero"
    # A Spend is money out, and a Refund and a Deposit are money in. Ignore fits either.
    add_check_constraint :budget_filing_rules,
      "amount IS NULL OR outcome = 'ignore' OR (outcome = 'spend' AND amount < 0) OR (outcome IN ('refund', 'deposit') AND amount > 0)",
      name: "budget_filing_rules_amount_suits_outcome"
    add_check_constraint :budget_filing_rules, "(outcome IN ('spend', 'refund')) = (envelope_id IS NOT NULL)", name: "budget_filing_rules_envelope_for_outcome"

    # The rule that filed or ignored a bank transaction, which is read only while it's filed or ignored: un-filing and un-ignoring
    # clear it, and if its last record is deleted by hand it goes stale but inert, until the next filing or ignoring writes it again.
    add_reference :budget_bank_transactions, :filing_rule, foreign_key: { to_table: :budget_filing_rules, on_delete: :restrict }

    # What an Import did with its rows, which the summary says since the rows can be un-filed later: how many Filing rules filed, and
    # how many they ignored.
    add_column :budget_imports, :filed_by_rules, :integer, null: false, default: 0
    add_column :budget_imports, :ignored_by_rules, :integer, null: false, default: 0
    add_check_constraint :budget_imports, "filed_by_rules >= 0", name: "budget_imports_filed_by_rules_not_negative"
    add_check_constraint :budget_imports, "ignored_by_rules >= 0", name: "budget_imports_ignored_by_rules_not_negative"
  end
end
