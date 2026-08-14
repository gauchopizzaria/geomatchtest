FactoryBot.define do
  factory :mimo_item do
    name { "MyString" }
    description { "MyText" }
    icon { "MyString" }
    price_cents { 1 }
    price_currency { "MyString" }
    receiver_value_cents { 1 }
    receiver_value_currency { "MyString" }
    active { false }
    position { 1 }
  end
end
