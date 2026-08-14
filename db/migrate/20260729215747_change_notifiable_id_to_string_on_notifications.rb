class ChangeNotifiableIdToStringOnNotifications < ActiveRecord::Migration[8.1]
  # notifiable_id era bigint, o que corrompia silenciosamente (truncava para um
  # inteiro sem sentido) qualquer Notification apontando para um model com PK
  # uuid — como MimoTransaction. string comporta tanto bigint (Like, Match, ...)
  # quanto uuid (MimoTransaction) sem mudar nenhum comportamento existente:
  # Match.find("123") funciona exatamente igual a Match.find(123).
  def up
    change_column :notifications, :notifiable_id, :string, null: false
  end

  def down
    change_column :notifications, :notifiable_id, :bigint, null: false, using: "notifiable_id::bigint"
  end
end
