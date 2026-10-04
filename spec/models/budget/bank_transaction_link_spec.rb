require "rails_helper"

# One link table per kind of record a bank transaction is filed as, which each hold the bank transaction and the record, which
# comes from at most one bank transaction. The three are alike but for the record.
RSpec.describe "The links between a bank transaction and the records it was filed as", type: :model do
  {
    Budget::DepositLink => { factory: :budget_deposit_link, record: :deposit, table: "budget_deposit_links", money_in: true },
    Budget::SpendLink => { factory: :budget_spend_link, record: :spend, table: "budget_spend_links", money_in: false },
    Budget::RefundLink => { factory: :budget_refund_link, record: :refund, table: "budget_refund_links", money_in: true }
  }.each do |klass, details|
    describe klass do
      subject(:link) { build(details[:factory]) }

      let(:link_class) { klass }
      let(:record) { details[:record] }

      it { is_expected.to belong_to(:bank_transaction).class_name("Budget::BankTransaction") }
      it { is_expected.to belong_to(record) }

      it "uses the #{details[:table]} table" do
        expect(klass.table_name).to eq(details[:table])
      end

      it "is valid as built by the factory" do
        expect(link).to be_valid
      end

      it "refuses a bank transaction that's ignored, since one can't be both ignored and filed" do
        ignored = create(:budget_bank_transaction, :ignored, amount: details[:money_in] ? 10 : -10)

        link = build(details[:factory], bank_transaction: ignored)

        expect(link).not_to be_valid
        expect(link.errors.full_messages).to eq([ "Bank transaction is ignored, so it can't be filed" ])
      end

      describe "database constraints" do
        let!(:link) { create(details[:factory]) }

        def update_link(link, assignments)
          link_class.transaction(requires_new: true) { link_class.where(id: link.id).update_all(assignments) }
        end

        %w[ bank_transaction_id ].push("#{details[:record]}_id").each do |column|
          it "requires a #{column}" do
            expect { update_link(link, "#{column} = NULL") }.to raise_error(ActiveRecord::NotNullViolation)
          end
        end

        it "refuses a second link to the same record, which comes from at most one bank transaction" do
          other_bank_transaction = create(:budget_bank_transaction, account: link.bank_transaction.account, amount: details[:money_in] ? 10 : -10)
          second = build(details[:factory], bank_transaction: other_bank_transaction, record => link.public_send(record))

          expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
        end

        it "allows one bank transaction to have several records" do
          second = build(details[:factory], bank_transaction: link.bank_transaction)

          expect { second.save! }.not_to raise_error
          expect(link.bank_transaction.public_send(:"#{record}_links").count).to eq(2)
        end

        it "keeps a record with a link from being deleted without it" do
          record_class = link.public_send(record).class

          expect { record_class.where(id: link.public_send(:"#{record}_id")).delete_all }
            .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
        end

        it "keeps a bank transaction with a link from being deleted without it" do
          expect { Budget::BankTransaction.where(id: link.bank_transaction_id).delete_all }
            .to raise_error(ActiveRecord::StatementInvalid, /PG::RestrictViolation/)
        end
      end

      describe "the record it links" do
        it "has no import columns, since the core tables stay as they are (ADR 0002)" do
          columns = link_class.reflect_on_association(record).klass.column_names

          expect(columns).not_to include("bank_transaction_id", "import_id", "account_id", "external_id")
        end

        it "has the link, which goes when the record does, leaving the bank transaction unfiled" do
          link = create(details[:factory])
          bank_transaction = link.bank_transaction

          expect(link.public_send(record).bank_transaction_link).to eq(link)

          expect { link.public_send(record).destroy! }.to change(link_class, :count).by(-1)
          expect(bank_transaction.reload.state).to eq(:unfiled)
        end
      end
    end
  end
end
