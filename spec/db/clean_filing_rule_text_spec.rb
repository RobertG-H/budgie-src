require "rails_helper"
require Rails.root.join("db/migrate/20261005120000_clean_filing_rule_text")

# The migration that made a Filing rule's text be read without its numbers and symbols (#117) cleans the rules that were made before. It never
# deletes one, and leaves alone any it can't clean without a collision or a text under 3 characters.
RSpec.describe CleanFilingRuleText do
  let(:budget) { create(:budget) }
  let(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let(:account) { create(:budget_account, budget: budget) }

  # A rule as it was saved before: the model would clean its text now, so it's written past it.
  def old_rule(text, **attributes)
    create(:budget_filing_rule, budget: budget, envelope: groceries, text: "placeholder-#{SecureRandom.hex(3).tr("0-9", "a-j")}", **attributes).tap do |rule|
      Budget::FilingRule.where(id: rule.id).update_all([ "text = ?", text ])
    end.reload
  end

  def migrate
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "cleans the text of each rule the way a rule's text is saved now" do
    store = old_rule("loblaws #1234")
    etransfer = old_rule("internet banking e-transfer 106121984683 james graham-hu")
    presto = old_rule("presto fare/shwqfxpddf")
    already_clean = old_rule("costco")

    migrate

    expect(store.reload.text).to eq("loblaws")
    expect(etransfer.reload.text).to eq("internet banking e-transfer james graham-hu")
    expect(presto.reload.text).to eq("presto fare")
    expect(already_clean.reload.text).to eq("costco")
  end

  it "leaves a rule's updated_at alone, since that's when it was last edited, which breaks ties between rules" do
    rule = old_rule("loblaws #1234")
    rule.update_columns(updated_at: Time.zone.local(2026, 9, 1, 10))

    migrate

    expect(rule.reload).to have_attributes(text: "loblaws", updated_at: Time.zone.local(2026, 9, 1, 10))
  end

  it "keeps a rule's other conditions and what it does" do
    pinned = old_rule("loblaws #1234", account: account, amount: "-82.45")

    migrate

    expect(pinned.reload).to have_attributes(text: "loblaws", account_id: account.id, amount: BigDecimal("-82.45"), outcome: "spend", envelope_id: groceries.id)
  end

  it "gives the cleaned text to the most recently edited of rules that would collide, and leaves the others as they were" do
    oldest = old_rule("loblaws #1").tap { |rule| rule.update_columns(updated_at: 3.days.ago) }
    newest = old_rule("loblaws #3").tap { |rule| rule.update_columns(updated_at: 1.day.ago) }
    middle = old_rule("loblaws #2").tap { |rule| rule.update_columns(updated_at: 2.days.ago) }

    migrate

    expect(newest.reload.text).to eq("loblaws")
    expect([ middle, oldest ].map { |rule| rule.reload.text }).to eq([ "loblaws #2", "loblaws #1" ])
    expect(Budget::FilingRule.count).to eq(3)
  end

  it "doesn't take the text of a rule that's already clean" do
    clean = old_rule("loblaws")
    old = old_rule("loblaws #1234")

    migrate

    expect(clean.reload.text).to eq("loblaws")
    expect(old.reload.text).to eq("loblaws #1234")
  end

  it "doesn't count rules for another Account, amount or budget as collisions" do
    any_account = old_rule("loblaws #1")
    pinned = old_rule("loblaws #2", account: account)
    with_amount = old_rule("loblaws #3", amount: "-50")
    other_budget = create(:budget_filing_rule, budget: create(:budget), text: "placeholder-x").tap do |rule|
      Budget::FilingRule.where(id: rule.id).update_all([ "text = ?", "loblaws #4" ])
    end

    migrate

    expect([ any_account, pinned, with_amount, other_budget ].map { |rule| rule.reload.text }).to all(eq("loblaws"))
  end

  it "leaves a rule that would be under 3 characters as it was" do
    numbers = old_rule("#1234 56")
    short = old_rule("ab #12")

    migrate

    expect(numbers.reload.text).to eq("#1234 56")
    expect(short.reload.text).to eq("ab #12")
  end

  it "leaves every rule fitting what it fitted, cleaned or not" do
    bank_transaction = create(:budget_bank_transaction, account: account, description: "LOBLAWS #1029 TORONTO", amount: -40).reload
    cleaned = old_rule("loblaws #1234")
    left_alone = old_rule("loblaws #5678", account: account).tap { |rule| rule.update_columns(updated_at: 1.year.ago) }
    left_alone_too = old_rule("loblaws #9", account: account)

    before = [ cleaned, left_alone, left_alone_too ].map { |rule| rule.reload.fits?(bank_transaction) }
    migrate
    after = [ cleaned, left_alone, left_alone_too ].map { |rule| rule.reload.fits?(bank_transaction) }

    expect(before).to eq([ true, true, true ])
    expect(after).to eq(before)
  end

  it "can't be rolled back, since the old text isn't kept" do
    expect { ActiveRecord::Migration.suppress_messages { described_class.new.down } }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
