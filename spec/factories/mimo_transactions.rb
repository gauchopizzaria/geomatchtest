FactoryBot.define do
  factory :mimo_transaction do
    sender { nil }
    receiver { nil }
    mimo_item { nil }
    price_cents { 1 }
    price_currency { "MyString" }
    receiver_value_cents { 1 }
    receiver_value_currency { "MyString" }
    message { "MyText" }
    status { "MyString" }
  end
end
