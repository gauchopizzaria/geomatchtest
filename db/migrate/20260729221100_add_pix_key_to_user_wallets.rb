class AddPixKeyToUserWallets < ActiveRecord::Migration[8.1]
  def change
    add_column :user_wallets, :pix_key, :string
    add_column :user_wallets, :pix_key_type, :string
  end
end
