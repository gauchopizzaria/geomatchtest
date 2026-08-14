class AddDepositAmountToPayments < ActiveRecord::Migration[8.1]
  def change
    # Nullable: só preenchido para payment_type "wallet_deposit" — os demais
    # tipos continuam derivando o valor de `plan` (ver Payment#amount).
    add_column :payments, :deposit_amount_cents, :integer
    add_column :payments, :deposit_amount_currency, :string, default: "BRL"
  end
end
