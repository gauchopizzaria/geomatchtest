# Responder uma mensagem (estilo WhatsApp): reply_to aponta para a mensagem
# citada — sempre da MESMA conversa (validado em Message e no controller).
#
# on_delete: :nullify é obrigatório: "Apagar mensagem" e "Limpar conversa"
# destroem mensagens que podem já ter sido respondidas. Sem ele a chave
# estrangeira bloquearia essas exclusões; com ele a resposta continua
# existindo e só perde a citação.
#
# Idempotente: em produção (Render free, sem Shell) a coluna foi criada à mão
# antes desta migration rodar. Cada passo só é feito se ainda faltar, então ela
# completa o índice e a chave estrangeira sem falhar no que já existe.
class AddReplyToToMessages < ActiveRecord::Migration[8.1]
  def up
    add_column :messages, :reply_to_id, :bigint unless column_exists?(:messages, :reply_to_id)
    add_index  :messages, :reply_to_id unless index_exists?(:messages, :reply_to_id)

    unless foreign_key_exists?(:messages, :messages, column: :reply_to_id)
      add_foreign_key :messages, :messages, column: :reply_to_id, on_delete: :nullify
    end
  end

  def down
    remove_foreign_key :messages, column: :reply_to_id if foreign_key_exists?(:messages, :messages, column: :reply_to_id)
    remove_index :messages, :reply_to_id if index_exists?(:messages, :reply_to_id)
    remove_column :messages, :reply_to_id if column_exists?(:messages, :reply_to_id)
  end
end
