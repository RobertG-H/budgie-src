# What a record that belongs to an envelope shares in how it treats an archived one: it can't be added to it, or moved
# into it, but one that's already there can still be changed and deleted. `build` is given the envelope the record should
# have as `association` and the budget, and returns a new record, with any other envelope in the same budget.
RSpec.shared_examples "a record that refuses an archived envelope" do |association:, label:, build:|
  let(:budget) { create(:budget) }
  let(:archived) { create(:budget_envelope, budget: budget, archived_at: Time.current) }
  let(:active) { create(:budget_envelope, budget: budget) }

  it "can be added to an envelope in use" do
    expect(instance_exec(active, budget, &build)).to be_valid
  end

  it "can't be added to an archived envelope, and the error on #{label} says it's archived" do
    record = instance_exec(archived, budget, &build)

    expect(record).not_to be_valid
    expect(record.errors[association]).to eq([ "is archived" ])
    expect(record.errors.full_messages).to include("#{label} is archived")
  end

  it "can't be moved into an archived envelope, and keeps the envelope it has" do
    record = instance_exec(active, budget, &build).tap(&:save!)

    record.public_send(:"#{association}=", archived)

    expect(record).not_to be_valid
    expect(record.errors[association]).to eq([ "is archived" ])
    expect(record.save).to be(false)
    expect(record.class.find(record.id).public_send(association)).to eq(active)
  end

  it "can still be changed and deleted once its envelope is archived" do
    record = instance_exec(active, budget, &build).tap(&:save!)
    active.update_column(:archived_at, Time.current)
    record = record.class.find(record.id)

    expect(record.update(description: "Corrected", amount: 5)).to be(true)
    expect(record.destroy).to be_truthy
  end
end
