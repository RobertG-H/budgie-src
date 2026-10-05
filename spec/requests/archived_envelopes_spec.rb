require "rails_helper"

RSpec.describe "Archived envelopes", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let!(:groceries) { create(:budget_envelope, budget: budget, name: "Groceries") }
  let!(:gym) { create(:budget_envelope, budget: budget, name: "Gym") }
  let(:others_envelope) { create(:budget_envelope, name: "Someone else's") }
  let(:september) { Date.new(2026, 9, 1) }
  let(:october) { Date.new(2026, 10, 1) }

  # Today is in October 2026.
  before do
    travel_to Time.utc(2026, 10, 15, 16)
    sign_in_as budget.user
  end

  # Puts the envelope away without the checks, for an envelope with records that archiving would refuse.
  def archive(envelope)
    envelope.update_column(:archived_at, Time.current)
  end

  # What a select offers, as one line of text per option.
  def choices(name)
    css_select("select[name='#{name}'] option").map { |option| option.text.strip }
  end

  describe "POST /envelopes/:envelope_id/archive" do
    it "archives an envelope whose Available is 0 and that has nothing later, and goes back to its page with a notice" do
      post envelope_archive_path(gym), params: { month: "2026-10" }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_envelope_path("2026-10", gym))
      expect(gym.reload).to be_archived
      follow_redirect!
      assert_select "[role=status]", text: "Envelope archived."
      assert_select "h1 .badge", text: "Archived"
    end

    it "works from a past month's page and goes back to it, but is judged as of today" do
      create(:budget_assignment, envelope: gym, month: september, amount: 40)
      create(:budget_envelope_reallocation, from_envelope: gym, to_envelope: groceries, date: Date.new(2026, 10, 5), amount: 40)

      post envelope_archive_path(gym), params: { month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-09", gym))
      expect(gym.reload).to be_archived
    end

    it "is refused from a past month's page when today's Available isn't 0, though that month's is" do
      create(:budget_assignment, envelope: gym, month: september, amount: 40)
      create(:budget_spend, envelope: gym, date: Date.new(2026, 9, 20), amount: 40)
      create(:budget_assignment, envelope: gym, month: october, amount: 15)

      post envelope_archive_path(gym), params: { month: "2026-09" }

      expect(response).to redirect_to(month_envelope_path("2026-09", gym))
      expect(gym.reload).not_to be_archived
    end

    it "goes back to the current month's page without a month" do
      post envelope_archive_path(gym)

      expect(response).to redirect_to(month_envelope_path("2026-10", gym))
    end

    {
      "Available above 0" => [
        -> { create(:budget_assignment, envelope: gym, month: october, amount: 12) },
        "Available is $12.00 in October 2026. Lower this month's Assigned, spend it or reallocate it first."
      ],
      "Available below 0" => [
        -> { create(:budget_spend, envelope: gym, date: Date.new(2026, 10, 2), amount: 12) },
        "Available is -$12.00 in October 2026. Assign more to it or reallocate money to it first."
      ],
      "Assigned entered ahead" => [
        -> { create(:budget_assignment, envelope: gym, month: Date.new(2026, 11, 1), amount: 12) },
        "It has Assigned, Spends, Refunds or Reallocations after October 2026. Clear them first."
      ],
      "a Spend dated next month" => [
        -> { create(:budget_spend, envelope: gym, date: Date.new(2026, 11, 2), amount: 12) },
        "It has Assigned, Spends, Refunds or Reallocations after October 2026. Clear them first."
      ]
    }.each do |reason, (set_up, message)|
      it "is refused with #{reason}, with an alert on the envelope's page saying what to do, and changes nothing" do
        instance_exec(&set_up)

        post envelope_archive_path(gym), params: { month: "2026-10" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(month_envelope_path("2026-10", gym))
        expect(gym.reload).not_to be_archived
        follow_redirect!
        assert_select "[role=alert]", text: message
        assert_select "[role=status]", count: 0
        assert_select "h1 .badge", count: 0
      end
    end

    it "changes nothing for an envelope that's already archived" do
      archived_at = Time.zone.local(2026, 6, 1)
      gym.update_column(:archived_at, archived_at)

      post envelope_archive_path(gym), params: { month: "2026-10" }

      expect(gym.reload.archived_at).to eq(archived_at)
    end

    it "is a 404 for another user's envelope, and changes nothing" do
      post envelope_archive_path(others_envelope), params: { month: "2026-10" }

      expect(response).to have_http_status(:not_found)
      expect(others_envelope.reload).not_to be_archived
    end

    it "is a 404 for a month that isn't one" do
      post envelope_archive_path(gym), params: { month: "nonsense" }

      expect(response).to have_http_status(:not_found)
      expect(gym.reload).not_to be_archived
    end
  end

  describe "DELETE /envelopes/:envelope_id/archive" do
    before { archive(gym) }

    it "unarchives, gives it no Assigned, and goes back to its page for the same month with a notice" do
      delete envelope_archive_path(gym), params: { month: "2026-09" }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(month_envelope_path("2026-09", gym))
      expect(gym.reload).not_to be_archived
      expect(gym.assignments).to be_empty
      follow_redirect!
      assert_select "[role=status]", text: "Envelope unarchived."
      assert_select "h1 .badge", count: 0
    end

    it "is a 404 for another user's envelope, and changes nothing" do
      archive(others_envelope)

      delete envelope_archive_path(others_envelope), params: { month: "2026-10" }

      expect(response).to have_http_status(:not_found)
      expect(others_envelope.reload).to be_archived
    end
  end

  describe "the envelope page" do
    it "has Archive beside Edit and Delete for an envelope in use, with New spend, New refund and Reallocate" do
      get month_envelope_path("2026-10", gym)

      assert_select "h1 .badge", count: 0
      assert_select "form[action='#{envelope_archive_path(gym)}'][method=post]" do
        assert_select "input[name=_method]", count: 0
        assert_select "input[type=hidden][name=month][value='2026-10']"
        assert_select "button", text: "Archive"
      end
      assert_select "button", text: "Unarchive", count: 0
      assert_select "a", text: "Edit"
      assert_select "a", text: "New spend"
      assert_select "a", text: "New refund"
      assert_select "a", text: "Reallocate"
    end

    context "for an archived envelope" do
      before do
        create(:budget_assignment, envelope: gym, month: october, amount: 40)
        create(:budget_spend, envelope: gym, description: "Membership", date: Date.new(2026, 10, 2), amount: 40)
        create(:budget_refund, envelope: gym, description: "Towel return", date: Date.new(2026, 10, 3), amount: 5)
        create(:budget_envelope_reallocation, from_envelope: gym, to_envelope: groceries, description: "Moved to food", date: Date.new(2026, 10, 4), amount: 5)
        archive(gym)
      end

      it "has an Archived badge by the title, and Unarchive where Archive was" do
        get month_envelope_path("2026-10", gym)

        assert_select "h1", text: /Gym\s+Archived/
        assert_select "h1 .badge", text: "Archived"
        assert_select "form[action='#{envelope_archive_path(gym)}'][method=post]" do
          assert_select "input[name=_method][value=delete]"
          assert_select "input[type=hidden][name=month][value='2026-10']"
          assert_select "button", text: "Unarchive"
        end
        assert_select "button", text: "Archive", count: 0
        assert_select "a", text: "Edit"
        assert_select "button", text: "Delete"
      end

      it "has no New spend, New refund or Reallocate" do
        get month_envelope_path("2026-10", gym)

        assert_select "a", text: "New spend", count: 0
        assert_select "a", text: "New refund", count: 0
        assert_select "a", text: "Reallocate", count: 0
        assert_select "a[href*='/spends/new'], a[href*='/refunds/new'], a[href*='/reallocations/new']", count: 0
      end

      it "lists its Spends, Refunds and Reallocations as any envelope's does" do
        get month_envelope_path("2026-10", gym)

        assert_select "h2", text: "Spends"
        assert_select "li a[href^='#{edit_spend_path(Budget::Spend.sole)}']", text: /Membership/
        assert_select "h2", text: "Refunds"
        assert_select "li", text: /Towel return/
        assert_select "h2", text: "Reallocations"
        assert_select "li", text: /Moved to food.*To Groceries/m
      end

      it "still shows its figures" do
        get month_envelope_path("2026-10", gym)

        assert_select ".stat-title [aria-describedby]", text: "Assigned"
        assert_select ".stats", text: /Assigned.*\$40\.00/m
      end
    end

    it "shows an archived envelope's page in a month where it has no figures" do
      archive(gym)

      get month_envelope_path("2026-12", gym)

      expect(response).to have_http_status(:ok)
      assert_select "h1 .badge", text: "Archived"
    end
  end

  describe "the month view" do
    before do
      create(:budget_assignment, envelope: gym, month: september, amount: 40)
      create(:budget_spend, envelope: gym, date: Date.new(2026, 9, 14), amount: 40)
      create(:budget_assignment, envelope: groceries, month: september, amount: 10)
      archive(gym)
    end

    def row_names
      css_select("tbody tr[id] td:first-child").map { |cell| cell.text.squish }
    end

    it "shows an archived envelope in a month where it has figures, with an Archived badge and its Assigned as plain text" do
      get month_path("2026-09")

      expect(row_names).to eq([ "Groceries", "Gym Archived" ])
      assert_select "tr#envelope_#{gym.id}" do
        assert_select "td:first-child .badge", text: "Archived"
        assert_select "td:nth-child(3)", text: "$40.00"
        assert_select "td:nth-child(3) button, td:nth-child(3) form, td:nth-child(3) turbo-frame", count: 0
      end
      assert_select "tr#envelope_#{groceries.id} td:nth-child(3) button"
      assert_select "tr#envelope_#{groceries.id} .badge", count: 0
    end

    it "doesn't show it in a month where every figure is zero, and still shows an envelope in use" do
      get month_path("2026-11")

      expect(row_names).to eq([ "Groceries" ])
    end

    it "shows it in the later month when a change to an old record makes a figure non-zero" do
      Budget::Spend.sole.update!(amount: 30)

      get month_path("2026-11")

      expect(row_names).to eq([ "Groceries", "Gym Archived" ])
    end

    it "lists every archived envelope in an Archived envelopes section below the table, each linking to its page for the month being viewed" do
      archive(create(:budget_envelope, budget: budget, name: "Bike"))

      get month_path("2026-11")

      assert_select "details" do
        assert_select "summary", text: "Archived envelopes"
        assert_select "a[href='#{month_envelope_path("2026-11", gym)}']", text: "Gym"
        assert_select "a[href='#{month_envelope_path("2026-11", Budget::Envelope.find_by!(name: "Bike"))}']", text: "Bike"
      end
      assert_select "table + details, div + details"
    end

    it "has no Archived envelopes section when the budget has no archived envelope" do
      gym.update_column(:archived_at, nil)

      get month_path("2026-09")

      assert_select "details summary", text: "Archived envelopes", count: 0
      assert_select "main", text: /Archived envelopes/, count: 0
    end

    it "shows the empty state, and the section, when every envelope is archived and none has figures this month" do
      archive(groceries)
      Budget::Assignment.where(envelope: groceries).delete_all

      get month_path("2026-11")

      assert_select "table", count: 0
      assert_select "main p", text: "All your envelopes are archived."
      assert_select "main p", text: "You don't have any envelopes yet.", count: 0
      assert_select ".border-dashed a[href='#{new_envelope_path(month: "2026-11", from: "month")}']", text: "New envelope"
      assert_select "details summary", text: "Archived envelopes"
    end

    it "still says there are no envelopes yet for a budget with none at all" do
      Budget::Spend.delete_all
      Budget::Assignment.delete_all
      budget.envelopes.delete_all

      get month_path("2026-11")

      assert_select "main p", text: "You don't have any envelopes yet."
      assert_select "details summary", text: "Archived envelopes", count: 0
    end

    it "leaves Ready to Assign counting its Assigned in the months it had it" do
      get month_path("2026-09")

      assert_select "#ready-to-assign dl > div", text: /Assigned\s*\$50\.00/
    end
  end

  describe "the pickers" do
    before { archive(gym) }

    it "leave an archived envelope out of the Spend form, and out of the Refund form" do
      get new_spend_path(month: "2026-10", from: "month")
      expect(choices("spend[envelope_id]")).to eq([ "Choose an envelope", "Groceries" ])

      get new_refund_path(month: "2026-10", from: "month")
      expect(choices("refund[envelope_id]")).to eq([ "Choose an envelope", "Groceries" ])
    end

    it "leave an archived envelope out of both From and To on the Reallocate form" do
      get new_reallocation_path(month: "2026-10", from: "month")

      expect(choices("reallocation[from_envelope_id]")).to eq([ "Choose an envelope", "Groceries" ])
      expect(choices("reallocation[to_envelope_id]")).to eq([ "Choose an envelope", "Ready to Assign", "Groceries" ])
    end

    it "treat an archived envelope in ?envelope= as no envelope" do
      get new_spend_path(month: "2026-10", from: "envelope", envelope: gym.id)
      assert_select "select[name='spend[envelope_id]'] option[selected]", count: 0

      get new_refund_path(month: "2026-10", from: "envelope", envelope: gym.id)
      assert_select "select[name='refund[envelope_id]'] option[selected]", count: 0

      get new_reallocation_path(month: "2026-10", from: "envelope", envelope: gym.id)
      assert_select "select[name='reallocation[from_envelope_id]'] option[selected]", count: 0
    end

    it "keep an edit form's own envelope, archived or not, and no other archived envelope" do
      archive(create(:budget_envelope, budget: budget, name: "Bike"))
      unarchived = groceries
      spend = create(:budget_spend, envelope: unarchived, date: Date.new(2026, 10, 2))
      gym.update_column(:archived_at, nil)
      in_gym = create(:budget_spend, envelope: gym, date: Date.new(2026, 10, 2))
      archive(gym)

      get edit_spend_path(in_gym, month: "2026-10", from: "month")
      expect(choices("spend[envelope_id]")).to eq([ "Groceries", "Gym" ])
      assert_select "select[name='spend[envelope_id]'] option[selected]", text: "Gym"

      get edit_spend_path(spend, month: "2026-10", from: "month")
      expect(choices("spend[envelope_id]")).to eq([ "Groceries" ])
    end

    it "keep an archived envelope in a Refund's and a Reallocation's edit forms, as From" do
      gym.update_column(:archived_at, nil)
      refund = create(:budget_refund, envelope: gym, date: Date.new(2026, 10, 2))
      reallocation = create(:budget_envelope_reallocation, from_envelope: gym, to_envelope: groceries, date: Date.new(2026, 10, 2))
      to_ready_to_assign = create(:budget_ready_to_assign_reallocation, envelope: gym, date: Date.new(2026, 10, 2))
      archive(gym)

      get edit_refund_path(refund, month: "2026-10", from: "month")
      expect(choices("refund[envelope_id]")).to eq([ "Groceries", "Gym" ])

      get edit_envelope_reallocation_path(reallocation, month: "2026-10", from: "month")
      expect(choices("reallocation[from_envelope_id]")).to eq([ "Groceries", "Gym" ])
      assert_select "select[name='reallocation[from_envelope_id]'] option[selected]", text: "Gym"

      get edit_ready_to_assign_reallocation_path(to_ready_to_assign, month: "2026-10", from: "month")
      expect(choices("reallocation[from_envelope_id]")).to eq([ "Groceries", "Gym" ])
    end
  end

  describe "records sent for an archived envelope by hand" do
    before { archive(gym) }

    let(:fields) { { description: "Sneaky", date: "2026-10-12", amount: "10" } }

    it "refuse a Spend with a validation error on the envelope, and create nothing" do
      expect { post spends_path, params: { spend: fields.merge(envelope_id: gym.id), month: "2026-10" } }.not_to change(Budget::Spend, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select ".alert-error", text: /Envelope is archived/
    end

    it "refuse a Refund the same way" do
      expect { post refunds_path, params: { refund: fields.merge(envelope_id: gym.id), month: "2026-10" } }.not_to change(Budget::Refund, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select ".alert-error", text: /Envelope is archived/
    end

    it "refuse a Reallocation from it, to an envelope or to Ready to Assign, and one into it" do
      expect {
        post reallocations_path, params: { reallocation: fields.merge(from_envelope_id: gym.id, to_envelope_id: groceries.id), month: "2026-10" }
      }.not_to change(Budget::EnvelopeReallocation, :count)
      expect(response).to have_http_status(:unprocessable_content)
      assert_select ".alert-error", text: /From is archived/

      expect {
        post reallocations_path, params: { reallocation: fields.merge(from_envelope_id: gym.id, to_envelope_id: Reallocating::READY_TO_ASSIGN), month: "2026-10" }
      }.not_to change(Budget::ReadyToAssignReallocation, :count)
      expect(response).to have_http_status(:unprocessable_content)
      assert_select ".alert-error", text: /From is archived/

      expect {
        post reallocations_path, params: { reallocation: fields.merge(from_envelope_id: groceries.id, to_envelope_id: gym.id), month: "2026-10" }
      }.not_to change(Budget::EnvelopeReallocation, :count)
      expect(response).to have_http_status(:unprocessable_content)
      assert_select ".alert-error", text: /To is archived/
    end

    it "refuse an edit that moves a Spend, a Refund or a Reallocation into it, and change nothing" do
      spend = create(:budget_spend, envelope: groceries, date: Date.new(2026, 10, 2))
      refund = create(:budget_refund, envelope: groceries, date: Date.new(2026, 10, 2))
      other = create(:budget_envelope, budget: budget, name: "Other")
      reallocation = create(:budget_envelope_reallocation, from_envelope: groceries, to_envelope: other, date: Date.new(2026, 10, 2))
      to_ready_to_assign = create(:budget_ready_to_assign_reallocation, envelope: groceries, date: Date.new(2026, 10, 2))

      patch spend_path(spend), params: { spend: { envelope_id: gym.id }, month: "2026-10" }
      expect(response).to have_http_status(:unprocessable_content)
      patch refund_path(refund), params: { refund: { envelope_id: gym.id }, month: "2026-10" }
      expect(response).to have_http_status(:unprocessable_content)
      patch envelope_reallocation_path(reallocation), params: { reallocation: { from_envelope_id: gym.id }, month: "2026-10" }
      expect(response).to have_http_status(:unprocessable_content)
      patch ready_to_assign_reallocation_path(to_ready_to_assign), params: { reallocation: { from_envelope_id: gym.id }, month: "2026-10" }
      expect(response).to have_http_status(:unprocessable_content)

      expect([ spend, refund, to_ready_to_assign ].map { |record| record.reload.envelope_id }).to all(eq(groceries.id))
      expect(reallocation.reload.from_envelope_id).to eq(groceries.id)
    end

    it "let a record already in it be changed and deleted" do
      gym.update_column(:archived_at, nil)
      spend = create(:budget_spend, envelope: gym, description: "Membership", date: Date.new(2026, 10, 2))
      archive(gym)

      patch spend_path(spend), params: { spend: { description: "Corrected" }, month: "2026-10" }
      expect(spend.reload.description).to eq("Corrected")

      delete spend_path(spend), params: { month: "2026-10" }
      expect(Budget::Spend.exists?(spend.id)).to be(false)
    end
  end

  describe "an archived envelope's Assigned sent by hand" do
    before do
      create(:budget_assignment, envelope: gym, month: september, amount: 40)
      archive(gym)
    end

    def assigned
      Budget::Assignment.where(envelope: gym).order(:month).pluck(:month, :amount)
    end

    {
      "a new amount" => [ "2026-10", "25" ],
      "a changed one" => [ "2026-09", "75" ],
      "clearing one" => [ "2026-09", "" ]
    }.each do |change, (month, amount)|
      it "refuses #{change}, saying the envelope is archived, and changes nothing" do
        patch month_envelope_assignment_path(month, gym), params: { assignment: { amount: amount }, month: month }

        expect(response).to have_http_status(:unprocessable_content)
        assert_select ".text-error", text: "Gym is archived, so its Assigned can't be changed. Unarchive it first."
        expect(assigned).to eq([ [ september, 40 ] ])
      end
    end

    it "is accepted again once it's unarchived" do
      delete envelope_archive_path(gym), params: { month: "2026-09" }

      patch month_envelope_assignment_path("2026-09", gym), params: { assignment: { amount: "75" }, month: "2026-09" }

      expect(response).to have_http_status(:see_other)
      expect(assigned).to eq([ [ september, 75 ] ])
    end
  end

  describe "creating an envelope with an archived envelope's name" do
    it "is refused, and the error says it's an archived envelope" do
      archive(gym)

      expect { post envelopes_path, params: { envelope: { name: "gym" }, month: "2026-10" } }.not_to change(Budget::Envelope, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select ".alert-error", text: /Name is already used by an archived envelope/
    end
  end

  describe "renaming and changing the Starting balance of an archived envelope" do
    it "are allowed" do
      archive(gym)

      patch envelope_path(gym), params: { envelope: { name: "Old gym", starting_balance: "5" }, month: "2026-10" }

      expect(gym.reload).to have_attributes(name: "Old gym", starting_balance: 5)
      expect(gym).to be_archived
    end
  end
end
