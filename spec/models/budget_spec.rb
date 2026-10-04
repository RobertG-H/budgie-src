require "rails_helper"

RSpec.describe Budget, type: :model do
  subject { build(:budget) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to have_many(:envelopes).class_name("Budget::Envelope").dependent(:destroy) }
  it { is_expected.to have_many(:deposits).class_name("Budget::Deposit").dependent(:destroy) }
  it { is_expected.to have_many(:assignments).through(:envelopes) }
  it { is_expected.to validate_presence_of(:currency) }
  it { is_expected.to validate_inclusion_of(:currency).in_array(Budget::CURRENCIES.keys).with_message("isn't supported") }

  it "supports only three-letter uppercase codes" do
    expect(Budget::CURRENCIES.keys).to all(match(/\A[A-Z]{3}\z/))
  end

  it "rejects a currency that isn't supported" do
    budget = build(:budget, currency: "JPY")

    expect(budget).not_to be_valid
    expect(budget.errors.full_messages).to eq([ "Currency isn't supported" ])
  end

  it "names the currency options with their codes" do
    expect(Budget.currency_options).to include([ "Canadian dollar (CAD)", "CAD" ])
  end

  it "knows its currency's unit" do
    expect(build(:budget, currency: "GBP").currency_unit).to eq("£")
  end

  it "names nested models without the Budget prefix in routes and params" do
    expect(Budget::Envelope.model_name).to have_attributes(route_key: "envelopes", param_key: "envelope")
    expect(Budget::Deposit.model_name).to have_attributes(route_key: "deposits", param_key: "deposit")
    expect(Budget::Assignment.model_name).to have_attributes(route_key: "assignments", param_key: "assignment")
  end

  describe "#assignments" do
    it "are the Assigned amounts of its envelopes, and no other budget's" do
      budget = create(:budget)
      mine = create(:budget_assignment, envelope: create(:budget_envelope, budget: budget))
      create(:budget_assignment)

      expect(budget.assignments).to contain_exactly(mine)
    end
  end

  describe "being destroyed" do
    let(:budget) { create(:budget) }

    # Two envelopes with records, a Deposit, and an envelope with nothing recorded against it.
    before do
      groceries, rent = create_list(:budget_envelope, 2, budget: budget)
      create(:budget_envelope, budget: budget)
      [ groceries, rent ].each do |envelope|
        [ Date.new(2026, 9, 1), Date.new(2026, 10, 1) ].each { |month| create(:budget_assignment, envelope: envelope, month: month) }
      end
      create(:budget_deposit, budget: budget)
    end

    it "deletes its envelopes' records first, since an envelope with records can't be deleted, and then everything else" do
      expect { budget.destroy! }
        .to change(Budget, :count).by(-1)
        .and change(Budget::Envelope, :count).by(-3)
        .and change(Budget::Assignment, :count).by(-4)
        .and change(Budget::Deposit, :count).by(-1)
    end

    it "leaves another budget's records alone" do
      others = create(:budget_assignment)

      budget.destroy!

      expect(Budget::Assignment.all).to contain_exactly(others)
      expect(Budget::Envelope.exists?(others.envelope_id)).to be(true)
    end
  end

  describe "database constraints" do
    it "allows only one budget per user" do
      budget = create(:budget)

      expect { Budget.new(user: budget.user, currency: "USD").save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    [ "cad", "CA1" ].each do |currency|
      it "rejects the currency code #{currency}, which isn't three uppercase letters" do
        budget = create(:budget)

        expect { budget.update_column(:currency, currency) }.to raise_error(ActiveRecord::CheckViolation)
      end
    end

    it "keeps a user with a budget from being deleted without it" do
      budget = create(:budget)

      expect { User.where(id: budget.user_id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
    end
  end
end
