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

ActiveRecord::Schema[8.1].define(version: 2026_10_04_021620) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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

  create_table "budget_envelopes", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.string "name", null: false
    t.decimal "starting_balance", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "budget_id, lower((name)::text)", name: "index_budget_envelopes_on_budget_id_and_lower_name", unique: true
    t.index ["budget_id"], name: "index_budget_envelopes_on_budget_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "budget_envelopes_name_not_blank"
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

  add_foreign_key "budget_assignments", "budget_envelopes", column: "envelope_id", on_delete: :restrict
  add_foreign_key "budget_deposits", "budgets", on_delete: :restrict
  add_foreign_key "budget_envelopes", "budgets", on_delete: :restrict
  add_foreign_key "budgets", "users", on_delete: :restrict
  add_foreign_key "identities", "users"
  add_foreign_key "invites", "users"
  add_foreign_key "sessions", "users"
end
