FactoryBot.define do
  factory :withdrawal_request do
    user { nil }
    processed_by { nil }
    amount_cents { 1 }
    amount_currency { "MyString" }
    status { "MyString" }
    pix_key { "MyString" }
    pix_key_type { "MyString" }
    admin_notes { "MyText" }
    processed_at { "2026-07-29 18:08:18" }
  end
end
