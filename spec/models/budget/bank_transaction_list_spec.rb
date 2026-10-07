require "rails_helper"

RSpec.describe Budget::BankTransactionList do
  let(:budget) { create(:budget) }
  let!(:chequing) { create(:budget_account, budget: budget, name: "Chequing") }
  let!(:visa) { create(:budget_account, budget: budget, name: "Visa") }

  before { travel_to Time.utc(2026, 10, 14, 16) }

  def list_for(filter = {}, **keywords)
    Budget::BankTransactionList.parse(budget, filter.is_a?(Hash) ? filter.merge(keywords) : filter)
  end

  def listed(list)
    list.bank_transactions.newest_first.to_a
  end

  # A bank transaction in `state`, dated `date`, in `account`.
  def transaction(state, date, account: chequing, description: "#{state} #{date}")
    create(:budget_bank_transaction, *state_traits(state), account: account, date: date, description: description)
  end

  def state_traits(state)
    { unfiled: [], filed: [ :filed ], ignored: [ :ignored ] }.fetch(state)
  end

  describe "a bank transaction a sync found gone from Splitwise, which was neither filed nor ignored" do
    let(:splitwise_account) { create(:budget_account, :synced, budget: budget) }
    let!(:in_range) { create(:budget_bank_transaction, :removed, account: splitwise_account, date: Date.new(2026, 10, 5), description: "Removed this month") }
    let!(:out_of_range) { create(:budget_bank_transaction, :removed, account: splitwise_account, date: Date.new(2026, 8, 5), description: "Removed in August") }

    it "isn't in the Unfiled state, whatever its date" do
      expect(listed(list_for(state: "unfiled"))).to be_empty
    end

    it "is in the All state, with the filed and ignored ones, when it's in the range, and not otherwise" do
      expect(listed(list_for(state: "all"))).to eq([ in_range ])
      expect(listed(list_for(state: "all", date_from: "2026-08-01", date_to: "2026-08-31"))).to eq([ out_of_range ])
    end
  end

  describe "the state" do
    it "is All when it's blank, or isn't one of the four" do
      [ {}, { state: "" }, { state: "everything" }, { state: [ "filed" ] }, { state: { a: 1 } }, "//evil.test", nil ].each do |filter|
        expect(list_for(filter).state).to eq("all")
      end
    end

    it "is Unfiled, Filed or Ignored when it's asked for" do
      %w[ all unfiled filed ignored ].each do |state|
        expect(list_for(state: state).state).to eq(state)
      end
    end

    it "is only in the params it hands back when it isn't All" do
      expect(list_for(state: "all").to_params).not_to have_key(:state)
      expect(list_for(state: "filed").to_params).to include(state: "filed")
    end
  end

  describe "the Account" do
    it "is one of the budget's, found by its id" do
      expect(list_for(account: visa.id.to_s).account).to eq(visa)
    end

    it "is all Accounts when it's blank, unknown, another budget's, or isn't an id" do
      other = create(:budget_account)

      [ "", "abc", "0", "99999999999999999999", other.id.to_s, "#{visa.id}x", [ visa.id.to_s ] ].each do |value|
        expect(list_for(account: value).account).to be_nil
      end
    end

    it "has the budget's Accounts alphabetically, for the Account picker" do
      create(:budget_account, name: "Someone else's")
      aaa = create(:budget_account, budget: budget, name: "aaa savings")

      expect(list_for.accounts).to eq([ aaa, chequing, visa ])
    end
  end

  describe "the bank transactions" do
    it "are every unfiled one whatever its date, with the filed and ignored ones only in the range, in All" do
      old_unfiled = transaction(:unfiled, Date.new(2024, 1, 5))
      new_unfiled = transaction(:unfiled, Date.new(2026, 10, 5))
      in_range_filed = transaction(:filed, Date.new(2026, 10, 3))
      in_range_ignored = transaction(:ignored, Date.new(2026, 10, 2))
      transaction(:filed, Date.new(2026, 9, 30))
      transaction(:ignored, Date.new(2026, 11, 1))

      expect(listed(list_for)).to eq([ new_unfiled, in_range_filed, in_range_ignored, old_unfiled ])
    end

    it "are the range's own dates in All, inclusive, whatever it is" do
      before_range = transaction(:filed, Date.new(2026, 8, 31))
      from = transaction(:filed, Date.new(2026, 9, 1))
      to = transaction(:ignored, Date.new(2026, 9, 30))
      transaction(:filed, Date.new(2026, 10, 1))

      expect(listed(list_for(date_from: "2026-09-01", date_to: "2026-09-30"))).to match_array([ from, to ])
      expect(before_range).not_to be_nil
    end

    it "are the unfiled ones only, whatever their dates, in Unfiled, which the range doesn't apply to" do
      old = transaction(:unfiled, Date.new(2020, 1, 1))
      recent = transaction(:unfiled, Date.new(2026, 10, 1))
      transaction(:filed, Date.new(2026, 10, 1))
      transaction(:ignored, Date.new(2026, 10, 1))

      expect(listed(list_for(state: "unfiled", date_from: "2026-01-01", date_to: "2026-01-31"))).to eq([ recent, old ])
    end

    it "are the filed ones in the range, in Filed" do
      inside = transaction(:filed, Date.new(2026, 10, 3))
      transaction(:filed, Date.new(2026, 9, 3))
      transaction(:unfiled, Date.new(2026, 10, 3))
      transaction(:ignored, Date.new(2026, 10, 3))

      expect(listed(list_for(state: "filed"))).to eq([ inside ])
    end

    it "are the ignored ones in the range, in Ignored" do
      inside = transaction(:ignored, Date.new(2026, 10, 3))
      transaction(:ignored, Date.new(2026, 9, 3))
      transaction(:unfiled, Date.new(2026, 10, 3))
      transaction(:filed, Date.new(2026, 10, 3))

      expect(listed(list_for(state: "ignored"))).to eq([ inside ])
    end

    it "have a filed one with two links, and a split one, once, in All and in Filed" do
      split = transaction(:unfiled, Date.new(2026, 10, 3), description: "Costco")
      2.times { create(:budget_spend_link, bank_transaction: split) }

      expect(listed(list_for)).to eq([ split ])
      expect(listed(list_for(state: "filed"))).to eq([ split ])
    end

    it "are the Account's only, when there's one chosen" do
      mine = transaction(:unfiled, Date.new(2026, 10, 3), account: visa)
      mine_filed = transaction(:filed, Date.new(2026, 10, 4), account: visa)
      transaction(:unfiled, Date.new(2026, 10, 3), account: chequing)
      transaction(:filed, Date.new(2026, 10, 4), account: chequing)

      expect(listed(list_for(account: visa.id.to_s))).to eq([ mine_filed, mine ])
      expect(listed(list_for(account: visa.id.to_s, state: "unfiled"))).to eq([ mine ])
      expect(listed(list_for(account: visa.id.to_s, state: "filed"))).to eq([ mine_filed ])
    end

    it "are all Accounts' when the Account chosen isn't one of the budget's" do
      other = create(:budget_account)
      transaction(:unfiled, Date.new(2026, 10, 3), account: visa)
      transaction(:unfiled, Date.new(2026, 10, 3), account: chequing)

      expect(listed(list_for(account: other.id.to_s)).size).to eq(2)
    end

    it "never include another budget's" do
      theirs = create(:budget_bank_transaction, date: Date.new(2026, 10, 3))
      create(:budget_bank_transaction, :filed, date: Date.new(2026, 10, 3))
      create(:budget_bank_transaction, :ignored, date: Date.new(2026, 10, 3))
      mine = transaction(:unfiled, Date.new(2026, 10, 3))

      %w[ all unfiled filed ignored ].each do |state|
        expect(listed(list_for(state: state))).not_to include(theirs)
      end
      expect(listed(list_for)).to eq([ mine ])
      expect(listed(list_for(account: theirs.account_id.to_s))).to eq([ mine ])
    end

    it "are newest first by date, then id" do
      first = transaction(:unfiled, Date.new(2026, 10, 3))
      second = transaction(:unfiled, Date.new(2026, 10, 3))
      newest = transaction(:unfiled, Date.new(2026, 10, 4))

      expect(listed(list_for)).to eq([ newest, second, first ])
    end

    it "can be preloaded and paged like any relation" do
      transaction(:filed, Date.new(2026, 10, 3))

      page = list_for.bank_transactions.preload(:account, :deposit_links, :spend_links, :refund_links).newest_first.limit(51).offset(0).to_a

      expect(page.size).to eq(1)
    end
  end

  describe "the range" do
    it "is the current month when it's given none, and the dates when it is" do
      expect(list_for.date_range.to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
      expect(list_for(date_from: "2026-09-01", date_to: "2026-09-30").date_range.to_params).to eq(date_from: "2026-09-01", date_to: "2026-09-30")
    end

    it "is used by every state but Unfiled" do
      expect(list_for(state: "all")).to be_range_applies
      expect(list_for(state: "filed")).to be_range_applies
      expect(list_for(state: "ignored")).to be_range_applies
      expect(list_for(state: "unfiled")).not_to be_range_applies
    end

    it "is an error that falls back to this month when it can't be used" do
      list = list_for(date_from: "2026-10-31", date_to: "2026-10-01")

      expect(list.date_range).not_to be_valid
      expect(list.date_range.from).to eq(Date.new(2026, 10, 1))
    end
  end

  describe "the params it was made from" do
    it "hands back what it understood: the dates, the state and the Account" do
      list = list_for(date_from: "2026-09-01", date_to: "2026-09-30", state: "filed", account: visa.id.to_s)

      expect(list.to_params).to eq(date_from: "2026-09-01", date_to: "2026-09-30", state: "filed", account: visa.id.to_s)
    end

    it "drops what it doesn't understand, so it can't be made to hand back anything else" do
      list = list_for(date_from: "http://example.com", date_to: "//evil.test", state: "//evil.test", account: "javascript:alert(1)")

      expect(list.to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
    end

    it "takes ActionController::Parameters, a Hash with string keys, or nothing" do
      expect(list_for(ActionController::Parameters.new(state: "ignored")).state).to eq("ignored")
      expect(list_for({ "state" => "ignored" }).state).to eq("ignored")
      expect(list_for(nil).to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
      expect(list_for([ "x" ]).to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
    end

    it "can be limited to the Account alone, which is all that filing as guessed carries" do
      list = list_for(date_from: "2026-09-01", date_to: "2026-09-30", state: "filed", account: visa.id.to_s)

      expect(list.account_params).to eq(account: visa.id.to_s)
      expect(list_for.account_params).to eq({})
    end
  end
end
