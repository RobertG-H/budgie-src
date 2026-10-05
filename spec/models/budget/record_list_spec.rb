require "rails_helper"

RSpec.describe Budget::RecordList do
  let(:budget) { create(:budget) }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:dining_out) { create(:budget_envelope, budget: budget, name: "Dining out") }

  before { travel_to Time.utc(2026, 10, 14, 16) }

  # A list of the budget's records, from the params the Records page is given.
  def list_for(filter = {}, **keywords)
    Budget::RecordList.parse(budget, filter.is_a?(Hash) ? filter.merge(keywords) : filter)
  end

  # Every record the list has, as the page would show them, not paged.
  def listed(list)
    list.records(list.keys.to_a)
  end

  def deposit(date, amount: 100, month: date, budget: self.budget)
    create(:budget_deposit, budget: budget, date: date, month: month, amount: amount)
  end

  def spend(date, amount: 10, envelope: groceries)
    create(:budget_spend, envelope: envelope, date: date, amount: amount)
  end

  def refund(date, amount: 10, envelope: groceries)
    create(:budget_refund, envelope: envelope, date: date, amount: amount)
  end

  def reallocate(date, amount: 10, from: dining_out, to: groceries)
    create(:budget_envelope_reallocation, from_envelope: from, to_envelope: to, date: date, amount: amount)
  end

  def reallocate_to_ready_to_assign(date, amount: 10, envelope: dining_out)
    create(:budget_ready_to_assign_reallocation, envelope: envelope, date: date, amount: amount)
  end

  describe "the records" do
    it "interleaves all five kinds, newest first by date" do
      oldest = deposit(Date.new(2026, 10, 1))
      second = spend(Date.new(2026, 10, 2))
      third = refund(Date.new(2026, 10, 3))
      fourth = reallocate(Date.new(2026, 10, 4))
      newest = reallocate_to_ready_to_assign(Date.new(2026, 10, 5))

      expect(listed(list_for)).to eq([ newest, fourth, third, second, oldest ])
    end

    it "orders records of one date by when they were made, then by id, newest first, and by kind last, so the order is total" do
      first = deposit(Date.new(2026, 10, 5))
      travel 1.minute
      second = spend(Date.new(2026, 10, 5))
      third = spend(Date.new(2026, 10, 5))
      travel 1.minute
      fourth = refund(Date.new(2026, 10, 5))

      expect(listed(list_for)).to eq([ fourth, third, second, first ])
    end

    it "breaks a tie in everything else by kind, so the order is total" do
      paycheck = deposit(Date.new(2026, 10, 5))
      loblaws = spend(Date.new(2026, 10, 5))
      Budget::Spend.where(id: loblaws.id).update_all(id: paycheck.id, created_at: paycheck.created_at)

      expect(list_for.keys.to_a.map { |key| [ key.source, key.id ] }).to eq([ [ "deposit", paycheck.id ], [ "spend", paycheck.id ] ])
    end

    it "is the current month when it's given no range" do
      this_month = spend(Date.new(2026, 10, 1))
      last_day = spend(Date.new(2026, 10, 31))
      spend(Date.new(2026, 9, 30))
      spend(Date.new(2026, 11, 1))

      expect(listed(list_for)).to contain_exactly(this_month, last_day)
    end

    it "is the range it's given, inclusive of both ends" do
      spend(Date.new(2026, 8, 31))
      inside = [ spend(Date.new(2026, 9, 1)), refund(Date.new(2026, 9, 15)), deposit(Date.new(2026, 9, 30)) ]
      spend(Date.new(2026, 10, 1))

      expect(listed(list_for(date_from: "2026-09-01", date_to: "2026-09-30"))).to match_array(inside)
    end

    it "has the records of a range that spans years" do
      spend(Date.new(2025, 12, 31))
      inside = [ spend(Date.new(2026, 1, 1)), refund(Date.new(2026, 1, 2)) ]

      expect(listed(list_for(date_from: "2026-01-01", date_to: "2026-12-31"))).to match_array(inside)
    end

    it "is nothing for a budget with no records" do
      expect(listed(list_for)).to eq([])
      expect(list_for.totals).to have_attributes(money_in: 0, money_out: 0)
    end

    it "finds a Deposit by its date, and not by the month it counts toward" do
      paycheck = deposit(Date.new(2026, 9, 30), month: Date.new(2026, 10, 1))

      expect(listed(list_for(date_from: "2026-09-01", date_to: "2026-09-30"))).to eq([ paycheck ])
      expect(listed(list_for(date_from: "2026-10-01", date_to: "2026-10-31"))).to eq([])
    end

    it "includes the records of an archived envelope" do
      closed = create(:budget_envelope, budget: budget, name: "Closed")
      kept = spend(Date.new(2026, 10, 3), envelope: closed)
      closed.update_columns(archived_at: Time.current)

      records = listed(list_for)

      expect(records).to eq([ kept ])
      expect(records.first.envelope).to be_archived
    end

    it "never has another budget's records, of any kind" do
      other = create(:budget)
      other_envelope = create(:budget_envelope, budget: other)
      other_deposit = deposit(Date.new(2026, 10, 3), budget: other)
      create(:budget_spend, envelope: other_envelope, date: Date.new(2026, 10, 3))
      create(:budget_refund, envelope: other_envelope, date: Date.new(2026, 10, 3))
      create(:budget_envelope_reallocation, from_envelope: other_envelope, date: Date.new(2026, 10, 3))
      create(:budget_ready_to_assign_reallocation, envelope: other_envelope, date: Date.new(2026, 10, 3))
      mine = spend(Date.new(2026, 10, 3))

      expect(listed(list_for)).to eq([ mine ])
      expect(listed(list_for(envelope: other_envelope.id.to_s))).to eq([ mine ])
      expect(listed(list_for(kind: "deposit"))).to eq([])
      expect(other_deposit.budget).to eq(other)
    end

    it "has each record's envelope or envelopes loaded, with no query for them" do
      spend(Date.new(2026, 10, 1))
      refund(Date.new(2026, 10, 2))
      reallocate(Date.new(2026, 10, 3))
      reallocate_to_ready_to_assign(Date.new(2026, 10, 4))
      records = listed(list_for)

      queries = count_queries do
        records.each do |record|
          case record
          when Budget::Spend, Budget::Refund, Budget::ReadyToAssignReallocation then record.envelope.name
          when Budget::EnvelopeReallocation then [ record.from_envelope.name, record.to_envelope.name ]
          end
        end
      end

      expect(queries).to eq(0)
    end
  end

  describe "the Kind filter" do
    let!(:paycheck) { deposit(Date.new(2026, 10, 1)) }
    let!(:loblaws) { spend(Date.new(2026, 10, 2)) }
    let!(:rebate) { refund(Date.new(2026, 10, 3)) }
    let!(:covering) { reallocate(Date.new(2026, 10, 4)) }
    let!(:unspent) { reallocate_to_ready_to_assign(Date.new(2026, 10, 5)) }

    it "is every kind when it's blank, or isn't one" do
      expect(listed(list_for(kind: ""))).to eq([ unspent, covering, rebate, loblaws, paycheck ])
      expect(listed(list_for(kind: "everything"))).to eq([ unspent, covering, rebate, loblaws, paycheck ])
      expect(list_for(kind: "everything").kind).to be_nil
    end

    it "is one kind: Deposit, Spend or Refund" do
      expect(listed(list_for(kind: "deposit"))).to eq([ paycheck ])
      expect(listed(list_for(kind: "spend"))).to eq([ loblaws ])
      expect(listed(list_for(kind: "refund"))).to eq([ rebate ])
    end

    it "is both tables for a Reallocation" do
      expect(listed(list_for(kind: "reallocation"))).to eq([ unspent, covering ])
    end
  end

  describe "the Envelope filter" do
    let!(:paycheck) { deposit(Date.new(2026, 10, 1)) }
    let!(:loblaws) { spend(Date.new(2026, 10, 2)) }
    let!(:takeout) { spend(Date.new(2026, 10, 2), envelope: dining_out) }
    let!(:rebate) { refund(Date.new(2026, 10, 3)) }
    let!(:covering) { reallocate(Date.new(2026, 10, 4), from: dining_out, to: groceries) }
    let!(:unspent) { reallocate_to_ready_to_assign(Date.new(2026, 10, 5), envelope: dining_out) }

    it "has an envelope's Spends and Refunds, and leaves out Deposits, which belong to no envelope" do
      records = listed(list_for(envelope: groceries.id.to_s))

      expect(records).not_to include(paycheck)
      expect(records).to include(loblaws, rebate)
      expect(records).not_to include(takeout, unspent)
    end

    it "finds a Reallocation between envelopes by either of its envelopes" do
      expect(listed(list_for(envelope: groceries.id.to_s))).to include(covering)
      expect(listed(list_for(envelope: dining_out.id.to_s))).to include(covering)
    end

    it "finds a Reallocation to Ready to Assign by its envelope" do
      expect(listed(list_for(envelope: dining_out.id.to_s))).to eq([ unspent, covering, takeout ])
    end

    it "can be one kind of one envelope" do
      expect(listed(list_for(envelope: dining_out.id.to_s, kind: "reallocation"))).to eq([ unspent, covering ])
      expect(listed(list_for(envelope: groceries.id.to_s, kind: "spend"))).to eq([ loblaws ])
      expect(listed(list_for(envelope: groceries.id.to_s, kind: "deposit"))).to eq([])
    end

    it "is all envelopes when the id is blank, isn't an id, or isn't one of this budget's" do
      other_envelope = create(:budget_envelope)

      [ "", "abc", "0", "-1", "99999999999999999999", other_envelope.id.to_s, "#{groceries.id}x" ].each do |value|
        list = list_for(envelope: value)

        expect(list.envelope).to be_nil
        expect(listed(list).size).to eq(6)
      end
    end

    it "finds an archived envelope's records" do
      groceries.update_columns(archived_at: Time.current)

      list = list_for(envelope: groceries.id.to_s)

      expect(list.envelope).to eq(groceries)
      expect(listed(list)).to include(loblaws, rebate, covering)
    end
  end

  describe "the params it was made from" do
    it "hands back what it understood, as the dates, the kind and the envelope" do
      list = list_for(date_from: "2026-09-01", date_to: "2026-09-30", kind: "spend", envelope: groceries.id.to_s)

      expect(list.to_params).to eq(date_from: "2026-09-01", date_to: "2026-09-30", kind: "spend", envelope: groceries.id.to_s)
    end

    it "hands back only the dates when there's no kind or envelope" do
      expect(list_for.to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
    end

    it "drops what it doesn't understand, so it can't be made to hand back anything else" do
      list = list_for(date_from: "http://example.com", date_to: "//evil.test", kind: "//evil.test", envelope: "javascript:alert(1)")

      expect(list.to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
      expect(list.date_range).not_to be_valid
    end

    it "takes ActionController::Parameters, a Hash with string keys, or nothing" do
      from_params = ActionController::Parameters.new(date_from: "2026-09-01", date_to: "2026-09-30", kind: "refund")
      from_strings = { "date_from" => "2026-09-01", "date_to" => "2026-09-30", "kind" => "refund" }

      expect(list_for(from_params).to_params).to eq(date_from: "2026-09-01", date_to: "2026-09-30", kind: "refund")
      expect(list_for(from_strings).to_params).to eq(date_from: "2026-09-01", date_to: "2026-09-30", kind: "refund")
      expect(list_for(nil).to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
      expect(list_for("//evil.test").to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
      expect(list_for([ "x" ]).to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
    end

    it "ignores a kind or envelope that isn't a string" do
      expect(list_for(kind: [ "spend" ], envelope: [ groceries.id ]).to_params).to eq(date_from: "2026-10-01", date_to: "2026-10-31")
      expect(list_for(kind: { a: 1 }).kind).to be_nil
    end

    it "has the budget's envelopes, alphabetically, archived ones too, for the Envelope picker" do
      closed = create(:budget_envelope, budget: budget, name: "Closed")
      closed.update_columns(archived_at: Time.current)
      create(:budget_envelope, name: "Someone else's")

      expect(list_for.envelopes).to eq([ closed, dining_out, groceries ])
    end
  end

  describe "the totals" do
    it "are Money in, the Deposits and Refunds, and Money out, the Spends, of the whole range" do
      deposit(Date.new(2026, 10, 1), amount: 3000)
      refund(Date.new(2026, 10, 2), amount: 12.5)
      spend(Date.new(2026, 10, 3), amount: 82.45)
      spend(Date.new(2026, 10, 4), amount: 17.55, envelope: dining_out)

      totals = list_for.totals

      expect(totals).to have_attributes(money_in: BigDecimal("3012.5"), money_out: BigDecimal("100"))
      expect(totals.money_in).to be_a(BigDecimal)
    end

    it "don't count Reallocations, of either kind, since they only change which envelope money is in" do
      deposit(Date.new(2026, 10, 1), amount: 100)
      reallocate(Date.new(2026, 10, 2), amount: 40)
      reallocate_to_ready_to_assign(Date.new(2026, 10, 3), amount: 25)

      expect(list_for.totals).to have_attributes(money_in: 100, money_out: 0)
    end

    it "count the whole range and not one page of it" do
      60.times { |i| spend(Date.new(2026, 10, 1) + (i % 28), amount: 1) }

      list = list_for
      page = list.keys.limit(Paginated::PER_PAGE).to_a

      expect(page.size).to eq(50)
      expect(list.totals.money_out).to eq(60)
    end

    it "follow the filters" do
      deposit(Date.new(2026, 10, 1), amount: 3000)
      refund(Date.new(2026, 10, 2), amount: 12, envelope: groceries)
      refund(Date.new(2026, 10, 2), amount: 7, envelope: dining_out)
      spend(Date.new(2026, 10, 3), amount: 20, envelope: groceries)
      spend(Date.new(2026, 9, 3), amount: 999, envelope: groceries)

      expect(list_for(envelope: groceries.id.to_s).totals).to have_attributes(money_in: 12, money_out: 20)
      expect(list_for(kind: "refund").totals).to have_attributes(money_in: 19, money_out: 0)
      expect(list_for(kind: "spend").totals).to have_attributes(money_in: 0, money_out: 20)
      expect(list_for(date_from: "2026-09-01", date_to: "2026-09-30").totals).to have_attributes(money_in: 0, money_out: 999)
    end

    it "are left out for Reallocations alone, which have no money in or out" do
      reallocate(Date.new(2026, 10, 2))

      expect(list_for(kind: "reallocation").totals).to be_nil
    end

    it "are zero when the filters leave nothing, such as Deposits of an envelope" do
      deposit(Date.new(2026, 10, 1), amount: 3000)

      expect(list_for(kind: "deposit", envelope: groceries.id.to_s).totals).to have_attributes(money_in: 0, money_out: 0)
    end
  end

  describe "the number of queries" do
    # Records of every kind, `count` of each.
    def make_records(count)
      count.times do |i|
        date = Date.new(2026, 10, 1) + (i % 28)
        deposit(date)
        spend(date)
        refund(date)
        reallocate(date)
        reallocate_to_ready_to_assign(date)
      end
    end

    def queries_for(list)
      count_queries do
        keys = list.keys.limit(Paginated::PER_PAGE + 1).to_a
        list.records(keys.first(Paginated::PER_PAGE))
        list.totals
        list.envelopes
      end
    end

    it "is the same for 5 records as for 50 of a kind" do
      make_records(1)
      small = queries_for(list_for)
      make_records(49)
      large = queries_for(list_for)

      expect(large).to eq(small)
      expect(Budget::RecordList.parse(budget, {}).keys.count).to eq(250)
    end

    it "is the same with every filter on, and is a handful" do
      make_records(1)
      filters = { kind: "reallocation", envelope: dining_out.id.to_s, date_from: "2026-10-01", date_to: "2026-10-31" }
      small = queries_for(list_for(filters))
      make_records(49)
      large = queries_for(list_for(filters))

      expect(large).to eq(small)
      expect(large).to be <= 8
    end
  end
end
