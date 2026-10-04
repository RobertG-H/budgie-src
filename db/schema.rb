# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_04_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "budget_accounts", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "budget_id, lower((name)::text)", name: "index_budget_accounts_on_budget_id_and_lower_name", unique: true
    t.check_constraint "btrim(name::text) <> ''::text", name: "budget_accounts_name_not_blank"
  end

  create_table "budget_assignments", force: :cascade do |t|
    t.bigint "envelope_id", null: false
    t.date "month", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["envelope_id", "month"], name: "index_budget_assignments_on_envelope_id_and_month", unique: true
    t.check_constraint "EXTRACT(day FROM month) = 1::numeric", name: "budget_assignments_month_first_of_month"
    t.check_constraint "amount > 0::numeric", name: "budget_assignments_amount_positive"
  end

  create_table "budget_bank_transactions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "import_id", null: false
    t.date "date", null: false
    t.string "description", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "content_key", null: false
    t.integer "occurrence", null: false
    t.virtual "normalized_description", type: :text, as: "lower(regexp_replace(btrim((description)::text), '\\s+'::text, ' '::text, 'g'::text))", stored: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "ignored_at"
    t.bigint "filing_rule_id"
    t.index ["account_id", "content_key", "occurrence"], name: "index_budget_bank_transactions_on_content_key_and_occurrence", unique: true
    t.index ["account_id", "date", "id"], name: "index_budget_bank_transactions_on_account_id_and_date_and_id"
    t.index ["filing_rule_id"], name: "index_budget_bank_transactions_on_filing_rule_id"
    t.index ["import_id"], name: "index_budget_bank_transactions_on_import_id"
    t.check_constraint "amount <> 0::numeric", name: "budget_bank_transactions_amount_not_zero"
    t.check_constraint "btrim(description::text) <> ''::text", name: "budget_bank_transactions_description_not_blank"
    t.check_constraint "content_key::text ~ '^[0-9a-f]{64}$'::text", name: "budget_bank_transactions_content_key_format"
    t.check_constraint "occurrence >= 1", name: "budget_bank_transactions_occurrence_positive"
  end

  create_table "budget_csv_formats", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.string "name", null: false
    t.integer "rows_to_skip", default: 0, null: false
    t.integer "column_count", null: false
    t.integer "date_column", null: false
    t.string "date_format", null: false
    t.integer "description_columns", null: false, array: true
    t.string "amount_style", null: false
    t.integer "amount_column"
    t.integer "money_in_column"
    t.integer "money_out_column"
    t.integer "direction_column"
    t.string "money_in_value"
    t.boolean "invert_sign", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "budget_id, lower((name)::text)", name: "index_budget_csv_formats_on_budget_id_and_lower_name", unique: true
    t.check_constraint "amount_style::text <> 'direction'::text OR amount_column IS NOT NULL AND amount_column >= 1 AND amount_column <= column_count AND direction_column IS NOT NULL AND direction_column >= 1 AND direction_column <= column_count AND amount_column <> direction_column AND money_in_value IS NOT NULL AND btrim(money_in_value::text) <> ''::text AND money_in_column IS NULL AND money_out_column IS NULL", name: "budget_csv_formats_direction_columns"
    t.check_constraint "amount_style::text <> 'in_and_out'::text OR money_in_column IS NOT NULL AND money_in_column >= 1 AND money_in_column <= column_count AND money_out_column IS NOT NULL AND money_out_column >= 1 AND money_out_column <= column_count AND money_in_column <> money_out_column AND amount_column IS NULL AND direction_column IS NULL AND money_in_value IS NULL", name: "budget_csv_formats_in_and_out_columns"
    t.check_constraint "amount_style::text <> 'signed'::text OR amount_column IS NOT NULL AND amount_column >= 1 AND amount_column <= column_count AND money_in_column IS NULL AND money_out_column IS NULL AND direction_column IS NULL AND money_in_value IS NULL", name: "budget_csv_formats_signed_columns"
    t.check_constraint "amount_style::text = ANY (ARRAY['signed'::character varying, 'in_and_out'::character varying, 'direction'::character varying]::text[])", name: "budget_csv_formats_amount_style_known"
    t.check_constraint "btrim(name::text) <> ''::text", name: "budget_csv_formats_name_not_blank"
    t.check_constraint "cardinality(description_columns) >= 1 AND (1 <= ALL (description_columns)) AND (column_count >= ALL (description_columns))", name: "budget_csv_formats_description_columns_within_count"
    t.check_constraint "column_count <= 100", name: "budget_csv_formats_column_count_at_most_100"
    t.check_constraint "column_count >= 1", name: "budget_csv_formats_column_count_positive"
    t.check_constraint "date_column >= 1 AND date_column <= column_count", name: "budget_csv_formats_date_column_within_count"
    t.check_constraint "date_format::text = ANY (ARRAY['YYYY-MM-DD'::character varying, 'MM/DD/YYYY'::character varying, 'DD/MM/YYYY'::character varying, 'YYYYMMDD'::character varying]::text[])", name: "budget_csv_formats_date_format_known"
    t.check_constraint "rows_to_skip <= 1000", name: "budget_csv_formats_rows_to_skip_at_most_1000"
    t.check_constraint "rows_to_skip >= 0", name: "budget_csv_formats_rows_to_skip_not_negative"
  end

  create_table "budget_deposit_links", force: :cascade do |t|
    t.bigint "bank_transaction_id", null: false
    t.bigint "deposit_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_transaction_id"], name: "index_budget_deposit_links_on_bank_transaction_id"
    t.index ["deposit_id"], name: "index_budget_deposit_links_on_deposit_id", unique: true
  end

  create_table "budget_deposits", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.string "description", null: false
    t.date "date", null: false
    t.date "month", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.text "notes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "month"], name: "index_budget_deposits_on_budget_id_and_month"
    t.check_constraint "EXTRACT(day FROM month) = 1::numeric", name: "budget_deposits_month_first_of_month"
    t.check_constraint "amount > 0::numeric", name: "budget_deposits_amount_positive"
    t.check_constraint "btrim(description::text) <> ''::text", name: "budget_deposits_description_not_blank"
    t.check_constraint "month = date_trunc('month'::text, date::timestamp without time zone)::date OR month = (date_trunc('month'::text, date::timestamp without time zone) + 'P1M'::interval)::date", name: "budget_deposits_month_of_date_or_next"
  end

  create_table "budget_envelope_reallocations", force: :cascade do |t|
    t.bigint "from_envelope_id", null: false
    t.bigint "to_envelope_id", null: false
    t.string "description", null: false
    t.date "date", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.text "notes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_envelope_id", "date"], name: "index_envelope_reallocations_on_from_envelope_id_and_date"
    t.index ["to_envelope_id", "date"], name: "index_envelope_reallocations_on_to_envelope_id_and_date"
    t.check_constraint "amount > 0::numeric", name: "budget_envelope_reallocations_amount_positive"
    t.check_constraint "btrim(description::text) <> ''::text", name: "budget_envelope_reallocations_description_not_blank"
    t.check_constraint "from_envelope_id <> to_envelope_id", name: "budget_envelope_reallocations_envelopes_differ"
  end

  create_table "budget_envelopes", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.string "name", null: false
    t.decimal "starting_balance", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "archived_at"
    t.index "budget_id, lower((name)::text)", name: "index_budget_envelopes_on_budget_id_and_lower_name", unique: true
    t.index ["budget_id"], name: "index_budget_envelopes_on_budget_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "budget_envelopes_name_not_blank"
  end

  create_table "budget_filing_rules", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.string "text", null: false
    t.bigint "account_id"
    t.decimal "amount", precision: 15, scale: 2
    t.string "outcome", null: false
    t.bigint "envelope_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_budget_filing_rules_on_account_id"
    t.index ["budget_id", "text", "account_id", "amount"], name: "index_budget_filing_rules_on_conditions", unique: true, nulls_not_distinct: true
    t.index ["envelope_id"], name: "index_budget_filing_rules_on_envelope_id"
    t.check_constraint "(outcome::text = ANY (ARRAY['spend'::character varying, 'refund'::character varying]::text[])) = (envelope_id IS NOT NULL)", name: "budget_filing_rules_envelope_for_outcome"
    t.check_constraint "amount IS NULL OR amount <> 0::numeric", name: "budget_filing_rules_amount_not_zero"
    t.check_constraint "amount IS NULL OR outcome::text = 'ignore'::text OR outcome::text = 'spend'::text AND amount < 0::numeric OR (outcome::text = ANY (ARRAY['refund'::character varying, 'deposit'::character varying]::text[])) AND amount > 0::numeric", name: "budget_filing_rules_amount_suits_outcome"
    t.check_constraint "char_length(btrim(text::text)) >= 3", name: "budget_filing_rules_text_at_least_3_characters"
    t.check_constraint "outcome::text = ANY (ARRAY['spend'::character varying, 'refund'::character varying, 'deposit'::character varying, 'ignore'::character varying]::text[])", name: "budget_filing_rules_outcome_known"
  end

  create_table "budget_imports", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "csv_format_id", null: false
    t.string "file_name", null: false
    t.integer "duplicates_skipped", default: 0, null: false
    t.integer "zero_rows_skipped", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "earliest_date"
    t.date "latest_date"
    t.integer "money_in_count", default: 0, null: false
    t.decimal "money_in_total", precision: 20, scale: 2, default: "0.0", null: false
    t.integer "money_out_count", default: 0, null: false
    t.decimal "money_out_total", precision: 20, scale: 2, default: "0.0", null: false
    t.date "first_row_date"
    t.string "first_row_description"
    t.decimal "first_row_amount", precision: 15, scale: 2
    t.integer "filed_by_rules", default: 0, null: false
    t.integer "ignored_by_rules", default: 0, null: false
    t.index ["account_id", "created_at"], name: "index_budget_imports_on_account_id_and_created_at"
    t.index ["csv_format_id"], name: "index_budget_imports_on_csv_format_id"
    t.check_constraint "(earliest_date IS NULL) = ((money_in_count + money_out_count) = 0) AND (latest_date IS NULL) = (earliest_date IS NULL) AND (earliest_date IS NULL OR earliest_date <= latest_date)", name: "budget_imports_dates_match_rows"
    t.check_constraint "(first_row_date IS NULL) = ((money_in_count + money_out_count) = 0) AND (first_row_description IS NULL) = (first_row_date IS NULL) AND (first_row_amount IS NULL) = (first_row_date IS NULL) AND (first_row_description IS NULL OR btrim(first_row_description::text) <> ''::text) AND (first_row_amount IS NULL OR first_row_amount <> 0::numeric)", name: "budget_imports_first_row_matches_rows"
    t.check_constraint "(money_in_count = 0) = (money_in_total = 0::numeric) AND money_in_total >= 0::numeric", name: "budget_imports_money_in_total_matches_count"
    t.check_constraint "(money_out_count = 0) = (money_out_total = 0::numeric) AND money_out_total <= 0::numeric", name: "budget_imports_money_out_total_matches_count"
    t.check_constraint "btrim(file_name::text) <> ''::text", name: "budget_imports_file_name_not_blank"
    t.check_constraint "duplicates_skipped >= 0", name: "budget_imports_duplicates_skipped_not_negative"
    t.check_constraint "filed_by_rules >= 0", name: "budget_imports_filed_by_rules_not_negative"
    t.check_constraint "ignored_by_rules >= 0", name: "budget_imports_ignored_by_rules_not_negative"
    t.check_constraint "money_in_count >= 0 AND money_out_count >= 0", name: "budget_imports_money_counts_not_negative"
    t.check_constraint "zero_rows_skipped >= 0", name: "budget_imports_zero_rows_skipped_not_negative"
  end

  create_table "budget_ready_to_assign_reallocations", force: :cascade do |t|
    t.bigint "envelope_id", null: false
    t.string "description", null: false
    t.date "date", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.text "notes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["envelope_id", "date"], name: "index_ready_to_assign_reallocations_on_envelope_id_and_date"
    t.check_constraint "amount > 0::numeric", name: "budget_ready_to_assign_reallocations_amount_positive"
    t.check_constraint "btrim(description::text) <> ''::text", name: "budget_ready_to_assign_reallocations_description_not_blank"
  end

  create_table "budget_refund_links", force: :cascade do |t|
    t.bigint "bank_transaction_id", null: false
    t.bigint "refund_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_transaction_id"], name: "index_budget_refund_links_on_bank_transaction_id"
    t.index ["refund_id"], name: "index_budget_refund_links_on_refund_id", unique: true
  end

  create_table "budget_refunds", force: :cascade do |t|
    t.bigint "envelope_id", null: false
    t.string "description", null: false
    t.date "date", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.text "notes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["envelope_id", "date"], name: "index_budget_refunds_on_envelope_id_and_date"
    t.check_constraint "amount > 0::numeric", name: "budget_refunds_amount_positive"
    t.check_constraint "btrim(description::text) <> ''::text", name: "budget_refunds_description_not_blank"
  end

  create_table "budget_spend_links", force: :cascade do |t|
    t.bigint "bank_transaction_id", null: false
    t.bigint "spend_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_transaction_id"], name: "index_budget_spend_links_on_bank_transaction_id"
    t.index ["spend_id"], name: "index_budget_spend_links_on_spend_id", unique: true
  end

  create_table "budget_spends", force: :cascade do |t|
    t.bigint "envelope_id", null: false
    t.string "description", null: false
    t.date "date", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.text "notes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["envelope_id", "date"], name: "index_budget_spends_on_envelope_id_and_date"
    t.check_constraint "amount > 0::numeric", name: "budget_spends_amount_positive"
    t.check_constraint "btrim(description::text) <> ''::text", name: "budget_spends_description_not_blank"
  end

  create_table "budgets", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "currency", limit: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "assignments_copied_through", null: false
    t.index ["user_id"], name: "index_budgets_on_user_id", unique: true
    t.check_constraint "EXTRACT(day FROM assignments_copied_through) = 1::numeric", name: "budgets_assignments_copied_through_first_of_month"
    t.check_constraint "currency::text ~ '^[A-Z]{3}$'::text", name: "budgets_currency_format"
  end

  create_table "identities", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "uid"], name: "index_identities_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "invites", force: :cascade do |t|
    t.string "email", null: false
    t.datetime "accepted_at"
    t.datetime "revoked_at"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_invites_on_email", unique: true
    t.index ["user_id"], name: "index_invites_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "last_active_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "name"
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "budget_accounts", "budgets", on_delete: :restrict
  add_foreign_key "budget_assignments", "budget_envelopes", column: "envelope_id", on_delete: :restrict
  add_foreign_key "budget_bank_transactions", "budget_accounts", column: "account_id", on_delete: :restrict
  add_foreign_key "budget_bank_transactions", "budget_filing_rules", column: "filing_rule_id", on_delete: :restrict
  add_foreign_key "budget_bank_transactions", "budget_imports", column: "import_id", on_delete: :restrict
  add_foreign_key "budget_csv_formats", "budgets", on_delete: :restrict
  add_foreign_key "budget_deposit_links", "budget_bank_transactions", column: "bank_transaction_id", on_delete: :restrict
  add_foreign_key "budget_deposit_links", "budget_deposits", column: "deposit_id", on_delete: :restrict
  add_foreign_key "budget_deposits", "budgets", on_delete: :restrict
  add_foreign_key "budget_envelope_reallocations", "budget_envelopes", column: "from_envelope_id", on_delete: :restrict
  add_foreign_key "budget_envelope_reallocations", "budget_envelopes", column: "to_envelope_id", on_delete: :restrict
  add_foreign_key "budget_envelopes", "budgets", on_delete: :restrict
  add_foreign_key "budget_filing_rules", "budget_accounts", column: "account_id", on_delete: :restrict
  add_foreign_key "budget_filing_rules", "budget_envelopes", column: "envelope_id", on_delete: :restrict
  add_foreign_key "budget_filing_rules", "budgets", on_delete: :restrict
  add_foreign_key "budget_imports", "budget_accounts", column: "account_id", on_delete: :restrict
  add_foreign_key "budget_imports", "budget_csv_formats", column: "csv_format_id", on_delete: :restrict
  add_foreign_key "budget_ready_to_assign_reallocations", "budget_envelopes", column: "envelope_id", on_delete: :restrict
  add_foreign_key "budget_refund_links", "budget_bank_transactions", column: "bank_transaction_id", on_delete: :restrict
  add_foreign_key "budget_refund_links", "budget_refunds", column: "refund_id", on_delete: :restrict
  add_foreign_key "budget_refunds", "budget_envelopes", column: "envelope_id", on_delete: :restrict
  add_foreign_key "budget_spend_links", "budget_bank_transactions", column: "bank_transaction_id", on_delete: :restrict
  add_foreign_key "budget_spend_links", "budget_spends", column: "spend_id", on_delete: :restrict
  add_foreign_key "budget_spends", "budget_envelopes", column: "envelope_id", on_delete: :restrict
  add_foreign_key "budgets", "users", on_delete: :restrict
  add_foreign_key "identities", "users"
  add_foreign_key "invites", "users"
  add_foreign_key "sessions", "users"
end
