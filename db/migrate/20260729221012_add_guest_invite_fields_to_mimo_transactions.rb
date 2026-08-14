class AddGuestInviteFieldsToMimoTransactions < ActiveRecord::Migration[8.1]
  # Fecha a lacuna documentada no MimoInviteService (Fase 2): permite enviar um
  # Mimo para um número de telefone que ainda não tem conta. receiver_id passa
  # a ser opcional — a MimoTransaction fica "pendente de resgate" até alguém se
  # cadastrar com esse telefone (fluxo de resgate em si é de uma fase futura).
  def change
    change_column_null :mimo_transactions, :receiver_id, true

    add_column :mimo_transactions, :receiver_phone, :string
    add_column :mimo_transactions, :invite_token, :string
    add_column :mimo_transactions, :claimed_at, :datetime

    add_index :mimo_transactions, :receiver_phone
    add_index :mimo_transactions, :invite_token, unique: true
  end
end
