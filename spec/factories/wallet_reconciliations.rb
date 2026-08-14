FactoryBot.define do
  factory :wallet_reconciliation do
    user_wallet { nil }
    reconciled_by { nil }
    expected_balance_cents { 1 }
    actual_balance_cents { 1 }
    discrepancy_cents { 1 }
    status { "MyString" }
    notes { "MyText" }
    reconciled_at { "2026-07-29 18:08:41" }
  end
end
