require "rails_helper"

RSpec.describe "Messages", type: :request do
  let(:user)     { create(:user, onboarding_completed: true) }
  let(:other)    { create(:user, onboarding_completed: true) }
  let(:match)    { Match.create!(user: user, matched_user: other) }
  let!(:original) { match.messages.create!(sender: other, content: "Tudo bem?") }

  before do
    sign_in user, scope: :user
    # Broadcast e push não são o objeto destes testes (e não podem sair da máquina)
    allow(MatchChannel).to receive(:broadcast_to)
    allow(PushNotificationJob).to receive(:perform_later)
  end

  def send_message(content:, reply_to_id: nil, to: match)
    payload = { content: content }
    payload[:reply_to_id] = reply_to_id if reply_to_id
    post "/matches/#{to.id}/messages", params: { message: payload }, as: :json
  end

  describe "POST /matches/:match_id/messages respondendo uma mensagem" do
    it "salva a resposta apontando para a mensagem citada" do
      send_message(content: "Tudo sim!", reply_to_id: original.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reply_to_id"]).to eq(original.id)
      expect(match.messages.order(:id).last.reply_to).to eq(original)
    end

    it "manda o resumo da mensagem citada no broadcast para o chat desenhar a citação" do
      send_message(content: "Tudo sim!", reply_to_id: original.id)

      expect(MatchChannel).to have_received(:broadcast_to).with(
        match,
        hash_including(message: hash_including(
          content: "Tudo sim!",
          reply_to: { id: original.id, sender_id: other.id, sender_name: other.display_name, content: "Tudo bem?" }
        ))
      )
    end

    # Segurança: um reply_to_id forjado não pode trazer, no broadcast, o texto
    # de uma conversa de outras pessoas.
    it "ignora a citação de uma mensagem de outra conversa, sem vazar o conteúdo" do
      stranger    = create(:user, onboarding_completed: true)
      other_match = Match.create!(user: other, matched_user: stranger)
      foreign     = other_match.messages.create!(sender: stranger, content: "segredo de outra conversa")

      send_message(content: "oi", reply_to_id: foreign.id)

      expect(response).to have_http_status(:ok)
      expect(match.messages.order(:id).last.reply_to_id).to be_nil
      expect(MatchChannel).not_to have_received(:broadcast_to).with(
        match, hash_including(message: hash_including(reply_to: hash_including(content: "segredo de outra conversa")))
      )
    end

    it "envia normalmente, sem citação, se a original já foi apagada" do
      gone_id = original.id
      original.destroy!

      send_message(content: "ainda quero responder", reply_to_id: gone_id)

      expect(response).to have_http_status(:ok)
      expect(match.messages.order(:id).last).to have_attributes(content: "ainda quero responder", reply_to_id: nil)
    end
  end

  describe "Message#reply_to" do
    it "não aceita citar mensagem de outra conversa (defesa no model)" do
      other_match = Match.create!(user: other, matched_user: create(:user))
      foreign     = other_match.messages.create!(sender: other, content: "x")

      reply = match.messages.build(sender: user, content: "y", reply_to: foreign)

      expect(reply).not_to be_valid
      expect(reply.errors[:reply_to]).to be_present
    end

    # "Apagar mensagem" e "Limpar conversa" destroem mensagens que podem já ter
    # sido respondidas — a chave estrangeira não pode bloquear isso.
    it "apagar a mensagem original mantém a resposta e só remove a citação" do
      reply = match.messages.create!(sender: user, content: "Tudo!", reply_to: original)

      expect { original.destroy! }.not_to raise_error
      expect(reply.reload.reply_to_id).to be_nil
    end

    it "limpar a conversa com respostas não quebra" do
      match.messages.create!(sender: user, content: "Tudo!", reply_to: original)

      delete "/matches/#{match.id}/clear_conversation", as: :json

      expect(response).to have_http_status(:no_content)
      expect(match.messages.count).to eq(0)
    end
  end
end
