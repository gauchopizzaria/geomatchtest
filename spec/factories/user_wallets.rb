FactoryBot.define do
  factory :user_wallet do
    user { nil }
    balance_cents { 1 }
    balance_currency { "MyString" }
    pending_withdrawal_cents { 1 }
    lifetime_earned_cents { 1 }
    lifetime_withdrawn_cents { 1 }
  end
end
