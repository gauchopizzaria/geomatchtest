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

ActiveRecord::Schema[8.1].define(version: 2026_08_14_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "action_cable_internal_channels", force: :cascade do |t|
    t.string "channel_class"
    t.bigint "connection_id"
    t.string "identifier"
    t.index ["id"], name: "index_action_cable_internal_channels_on_id", unique: true
  end

  create_table "action_cable_internal_connections", force: :cascade do |t|
    t.datetime "connected_at"
    t.string "identifier"
    t.index ["id"], name: "index_action_cable_internal_connections_on_id", unique: true
  end

  create_table "action_cable_internal_messages", force: :cascade do |t|
    t.bigint "channel_id"
    t.datetime "created_at"
    t.jsonb "payload"
    t.index ["id"], name: "index_action_cable_internal_messages_on_id", unique: true
  end

  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "admin_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "admin_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.bigint "target_id", null: false
    t.string "target_type", default: "User", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_admin_logs_on_action"
    t.index ["admin_id"], name: "index_admin_logs_on_admin_id"
    t.index ["created_at"], name: "index_admin_logs_on_created_at"
    t.index ["target_type", "target_id"], name: "index_admin_logs_on_target_type_and_target_id"
  end

  create_table "blocks", force: :cascade do |t|
    t.bigint "blocked_id", null: false
    t.bigint "blocker_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blocked_id"], name: "index_blocks_on_blocked_id"
    t.index ["blocker_id", "blocked_id"], name: "index_blocks_on_blocker_id_and_blocked_id", unique: true
    t.index ["blocker_id"], name: "index_blocks_on_blocker_id"
  end

  create_table "blog_categories", force: :cascade do |t|
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.index ["slug"], name: "index_blog_categories_on_slug", unique: true
  end

  create_table "blog_posts", force: :cascade do |t|
    t.bigint "blog_category_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.text "excerpt"
    t.string "featured_image"
    t.datetime "published_at"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["blog_category_id"], name: "index_blog_posts_on_blog_category_id"
    t.index ["published_at"], name: "index_blog_posts_on_published_at"
    t.index ["slug"], name: "index_blog_posts_on_slug", unique: true
    t.index ["user_id"], name: "index_blog_posts_on_user_id"
  end

  create_table "coupons", force: :cascade do |t|
    t.boolean "active", default: true
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "discount_type", null: false
    t.integer "duration_days"
    t.datetime "expires_at"
    t.jsonb "plan_codes", default: [], null: false
    t.datetime "updated_at", null: false
    t.integer "usage_limit"
    t.integer "used_count", default: 0
    t.index ["active"], name: "index_coupons_on_active"
    t.index ["code"], name: "index_coupons_on_code", unique: true
  end

  create_table "favorites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "favorited_user_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["favorited_user_id"], name: "index_favorites_on_favorited_user_id"
    t.index ["user_id", "favorited_user_id"], name: "index_favorites_on_user_id_and_favorited_user_id", unique: true
    t.index ["user_id"], name: "index_favorites_on_user_id"
  end

  create_table "likes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "is_like", default: true
    t.bigint "liked_id", null: false
    t.bigint "liker_id", null: false
    t.datetime "updated_at", null: false
    t.index ["liked_id"], name: "index_likes_on_liked_id"
    t.index ["liker_id", "liked_id"], name: "index_likes_on_liker_id_and_liked_id", unique: true
    t.index ["liker_id"], name: "index_likes_on_liker_id"
  end

  create_table "locations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_seen_at"
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_locations_on_user_id"
  end

  create_table "matches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "matched_user_id", null: false
    t.string "status"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["matched_user_id"], name: "index_matches_on_matched_user_id"
    t.index ["user_id"], name: "index_matches_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.bigint "match_id", null: false
    t.datetime "read_at"
    t.bigint "sender_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["id"], name: "index_messages_on_id", unique: true
    t.index ["match_id"], name: "index_messages_on_match_id"
    t.index ["sender_id"], name: "index_messages_on_sender_id"
  end

  create_table "mimo_items", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "icon"
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.integer "price_cents", default: 0, null: false
    t.string "price_currency", default: "BRL", null: false
    t.integer "receiver_value_cents", default: 0, null: false
    t.string "receiver_value_currency", default: "BRL", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_mimo_items_on_active"
    t.index ["name"], name: "index_mimo_items_on_name", unique: true
    t.index ["position"], name: "index_mimo_items_on_position"
  end

  create_table "mimo_transactions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.string "invite_token"
    t.text "message"
    t.bigint "mimo_item_id", null: false
    t.integer "mp_fee_cents", default: 0, null: false
    t.uuid "payment_id"
    t.integer "platform_fee_cents", default: 0, null: false
    t.integer "price_cents", null: false
    t.string "price_currency", default: "BRL", null: false
    t.bigint "receiver_id"
    t.string "receiver_phone"
    t.integer "receiver_value_cents", null: false
    t.string "receiver_value_currency", default: "BRL", null: false
    t.bigint "sender_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_mimo_transactions_on_created_at"
    t.index ["invite_token"], name: "index_mimo_transactions_on_invite_token", unique: true
    t.index ["mimo_item_id"], name: "index_mimo_transactions_on_mimo_item_id"
    t.index ["payment_id"], name: "index_mimo_transactions_on_payment_id", unique: true
    t.index ["receiver_id"], name: "index_mimo_transactions_on_receiver_id"
    t.index ["receiver_phone"], name: "index_mimo_transactions_on_receiver_phone"
    t.index ["sender_id", "receiver_id"], name: "index_mimo_transactions_on_sender_id_and_receiver_id"
    t.index ["sender_id"], name: "index_mimo_transactions_on_sender_id"
    t.index ["status"], name: "index_mimo_transactions_on_status"
  end

  create_table "notifications", force: :cascade do |t|
    t.string "action"
    t.bigint "actor_id", null: false
    t.datetime "created_at", null: false
    t.string "notifiable_id", null: false
    t.string "notifiable_type", null: false
    t.datetime "read_at"
    t.bigint "recipient_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_notifications_on_actor_id"
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["recipient_id", "read_at"], name: "index_notifications_on_recipient_id_and_read_at"
    t.index ["recipient_id"], name: "index_notifications_on_recipient_id"
  end

  create_table "payments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "deposit_amount_cents"
    t.string "deposit_amount_currency", default: "BRL"
    t.string "mercado_pago_checkout_url"
    t.string "mercado_pago_merchant_order_id"
    t.jsonb "mercado_pago_payload"
    t.string "mercado_pago_payment_id"
    t.string "mercado_pago_preference_id"
    t.datetime "paid_at"
    t.string "payment_type", default: "plan_purchase", null: false
    t.bigint "plan_id"
    t.string "state", default: "created", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["mercado_pago_payment_id"], name: "index_payments_on_mercado_pago_payment_id"
    t.index ["mercado_pago_preference_id"], name: "index_payments_on_mercado_pago_preference_id"
    t.index ["payment_type"], name: "index_payments_on_payment_type"
    t.index ["plan_id"], name: "index_payments_on_plan_id"
    t.index ["state"], name: "index_payments_on_state"
    t.index ["user_id"], name: "index_payments_on_user_id"
  end

  create_table "plans", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "duration_days", null: false
    t.integer "duration_months", default: 1, null: false
    t.jsonb "features", default: {}, null: false
    t.boolean "has_boost", default: false, null: false
    t.boolean "has_incognito", default: false, null: false
    t.boolean "is_recommended", default: false, null: false
    t.integer "max_likes_per_day", default: 50, null: false
    t.string "name", null: false
    t.integer "price_cents", default: 0, null: false
    t.string "price_currency", default: "BRL", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_plans_on_active"
    t.index ["code"], name: "index_plans_on_code", unique: true
    t.index ["features"], name: "index_plans_on_features", using: :gin
    t.index ["is_recommended"], name: "index_plans_on_is_recommended"
  end

  create_table "profiles", force: :cascade do |t|
    t.integer "age"
    t.text "bio"
    t.datetime "created_at", null: false
    t.integer "discovery_radius_km"
    t.string "display_name"
    t.string "gender"
    t.string "looking_for_gender"
    t.integer "max_age"
    t.integer "min_age"
    t.boolean "share_location"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_profiles_on_user_id"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "auth"
    t.datetime "created_at", null: false
    t.text "endpoint"
    t.string "p256dh"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "reactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "emoji", null: false
    t.bigint "message_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["message_id", "user_id"], name: "index_reactions_on_message_id_and_user_id", unique: true
    t.index ["message_id"], name: "index_reactions_on_message_id"
    t.index ["user_id"], name: "index_reactions_on_user_id"
  end

  create_table "reports", force: :cascade do |t|
    t.string "category", default: "other", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "reporter_id"
    t.datetime "resolved_at"
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_reports_on_category"
    t.index ["reporter_id"], name: "index_reports_on_reporter_id"
    t.index ["resolved_at"], name: "index_reports_on_resolved_at"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.text "channel"
    t.bigint "channel_hash"
    t.datetime "created_at", null: false
    t.text "payload"
    t.datetime "updated_at", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "stories", force: :cascade do |t|
    t.text "caption"
    t.datetime "created_at", null: false
    t.float "latitude"
    t.float "longitude"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["latitude", "longitude"], name: "index_stories_on_latitude_and_longitude"
    t.index ["user_id"], name: "index_stories_on_user_id"
  end

  create_table "user_coupons", force: :cascade do |t|
    t.datetime "applied_at", null: false
    t.bigint "coupon_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["coupon_id"], name: "index_user_coupons_on_coupon_id"
    t.index ["user_id", "coupon_id"], name: "index_user_coupons_on_user_id_and_coupon_id", unique: true
    t.index ["user_id"], name: "index_user_coupons_on_user_id"
  end

  create_table "user_wallets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "balance_cents", default: 0, null: false
    t.string "balance_currency", default: "BRL", null: false
    t.datetime "created_at", null: false
    t.integer "lifetime_earned_cents", default: 0, null: false
    t.integer "lifetime_withdrawn_cents", default: 0, null: false
    t.integer "pending_withdrawal_cents", default: 0, null: false
    t.string "pix_key"
    t.string "pix_key_type"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_user_wallets_on_user_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "address"
    t.boolean "admin", default: false, null: false
    t.jsonb "ai_moderation_details"
    t.float "ai_moderation_score"
    t.string "ai_moderation_status"
    t.string "apns_token"
    t.datetime "banned_at"
    t.text "bio"
    t.date "birthdate"
    t.string "city"
    t.string "country", default: "Brasil"
    t.datetime "created_at", null: false
    t.integer "education_level"
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "fcm_token"
    t.string "gender"
    t.string "hobbies"
    t.string "interested_in"
    t.boolean "invisible", default: false
    t.datetime "last_like_reset_at"
    t.datetime "last_location_updated_at"
    t.datetime "last_message_reset_at"
    t.datetime "last_seen_at"
    t.decimal "latitude", precision: 10, scale: 6
    t.integer "likes_count", default: 0
    t.decimal "longitude", precision: 10, scale: 6
    t.integer "messages_count", default: 0
    t.string "neighborhood"
    t.string "occupation"
    t.boolean "onboarding_completed", default: false, null: false
    t.integer "one_off_message_credits", default: 0, null: false
    t.string "phone"
    t.bigint "plan_id"
    t.jsonb "political_interests", default: []
    t.datetime "premium_until"
    t.string "provider"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.boolean "share_location"
    t.string "state"
    t.string "street"
    t.string "uid"
    t.datetime "updated_at", null: false
    t.string "username"
    t.boolean "verified", default: false
    t.string "zip_code"
    t.index ["admin"], name: "index_users_on_admin"
    t.index ["banned_at"], name: "index_users_on_banned_at"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["fcm_token"], name: "index_users_on_fcm_token", unique: true
    t.index ["last_location_updated_at"], name: "index_users_on_last_location_updated_at"
    t.index ["latitude", "longitude"], name: "index_users_on_latitude_and_longitude"
    t.index ["plan_id"], name: "index_users_on_plan_id"
    t.index ["premium_until"], name: "index_users_on_premium_until"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["username"], name: "index_users_on_username"
  end

  create_table "wallet_reconciliations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "actual_balance_cents", null: false
    t.datetime "created_at", null: false
    t.integer "discrepancy_cents", default: 0, null: false
    t.integer "expected_balance_cents", null: false
    t.text "notes"
    t.datetime "reconciled_at"
    t.bigint "reconciled_by_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_wallet_id", null: false
    t.index ["discrepancy_cents"], name: "index_wallet_reconciliations_on_discrepancy_cents"
    t.index ["reconciled_by_id"], name: "index_wallet_reconciliations_on_reconciled_by_id"
    t.index ["status"], name: "index_wallet_reconciliations_on_status"
    t.index ["user_wallet_id"], name: "index_wallet_reconciliations_on_user_wallet_id"
  end

  create_table "webhook_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action"
    t.integer "attempts", default: 0
    t.datetime "created_at", null: false
    t.string "external_id"
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.text "processing_errors"
    t.string "source", default: "mercadopago"
    t.string "status", default: "pending"
    t.string "topic"
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_webhook_events_on_external_id"
    t.index ["status", "topic"], name: "index_webhook_events_on_status_and_topic"
    t.index ["status"], name: "index_webhook_events_on_status"
  end

  create_table "withdrawal_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "admin_notes"
    t.integer "amount_cents", null: false
    t.string "amount_currency", default: "BRL", null: false
    t.datetime "created_at", null: false
    t.text "payout_error"
    t.string "payout_external_id"
    t.jsonb "payout_payload"
    t.string "payout_provider"
    t.datetime "payout_requested_at"
    t.string "payout_status"
    t.string "pix_key"
    t.string "pix_key_type"
    t.datetime "processed_at"
    t.bigint "processed_by_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["payout_provider", "payout_external_id"], name: "index_withdrawal_requests_on_payout_identity", unique: true, where: "(payout_external_id IS NOT NULL)"
    t.index ["payout_status"], name: "index_withdrawal_requests_on_payout_status"
    t.index ["processed_by_id"], name: "index_withdrawal_requests_on_processed_by_id"
    t.index ["status"], name: "index_withdrawal_requests_on_status"
    t.index ["user_id"], name: "index_withdrawal_requests_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "blocks", "users", column: "blocked_id"
  add_foreign_key "blocks", "users", column: "blocker_id"
  add_foreign_key "blog_posts", "blog_categories"
  add_foreign_key "blog_posts", "users"
  add_foreign_key "favorites", "users"
  add_foreign_key "favorites", "users", column: "favorited_user_id"
  add_foreign_key "likes", "users", column: "liked_id"
  add_foreign_key "likes", "users", column: "liker_id"
  add_foreign_key "locations", "users"
  add_foreign_key "matches", "users"
  add_foreign_key "matches", "users", column: "matched_user_id"
  add_foreign_key "messages", "matches"
  add_foreign_key "messages", "users", column: "sender_id"
  add_foreign_key "mimo_transactions", "mimo_items"
  add_foreign_key "mimo_transactions", "payments"
  add_foreign_key "mimo_transactions", "users", column: "receiver_id"
  add_foreign_key "mimo_transactions", "users", column: "sender_id"
  add_foreign_key "notifications", "users", column: "actor_id"
  add_foreign_key "notifications", "users", column: "recipient_id"
  add_foreign_key "payments", "plans"
  add_foreign_key "payments", "users"
  add_foreign_key "profiles", "users"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "reactions", "messages"
  add_foreign_key "reactions", "users"
  add_foreign_key "reports", "users", column: "reporter_id"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "stories", "users"
  add_foreign_key "user_coupons", "coupons"
  add_foreign_key "user_coupons", "users"
  add_foreign_key "user_wallets", "users"
  add_foreign_key "users", "plans"
  add_foreign_key "wallet_reconciliations", "user_wallets"
  add_foreign_key "wallet_reconciliations", "users", column: "reconciled_by_id"
  add_foreign_key "withdrawal_requests", "users"
  add_foreign_key "withdrawal_requests", "users", column: "processed_by_id"
end
