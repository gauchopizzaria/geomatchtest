# Responder uma mensagem (estilo WhatsApp): reply_to aponta para a mensagem
# citada — sempre da MESMA conversa (validado em Message e no controller).
#
# on_delete: :nullify é obrigatório: "Apagar mensagem" e "Limpar conversa"
# destroem mensagens que podem já ter sido respondidas. Sem ele a chave
# estrangeira bloquearia essas exclusões; com ele a resposta continua
# existindo e só perde a citação.
class AddReplyToToMessages < ActiveRecord::Migration[8.1]
  def change
    add_reference :messages, :reply_to,
                  foreign_key: { to_table: :messages, on_delete: :nullify },
                  index: true,
                  null: true
  end
end
