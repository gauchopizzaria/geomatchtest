class Message < ApplicationRecord
  include GlobalID::Identification

  enum :status, { sent: 0, delivered: 1, read: 2 }, default: :sent

  # Tamanho do trecho da mensagem citada (balão e barra "Respondendo a…").
  REPLY_PREVIEW_LENGTH = 120

  belongs_to :match
  belongs_to :sender, class_name: "User"
  # Mensagem respondida (arrastar para a direita no chat). Se a original for
  # apagada, o banco zera esta coluna (on_delete: :nullify).
  belongs_to :reply_to, class_name: "Message", optional: true
  has_many   :reactions, dependent: :destroy

  validates :content, presence: true
  validate  :reply_to_must_belong_to_same_match

  after_create_commit  :broadcast_message
  after_create_commit  :send_push_notification
  after_destroy_commit :broadcast_deletion

  # Resumo da mensagem citada, no formato que o chat_logic.js desenha.
  def reply_to_preview
    return nil unless reply_to

    {
      id:          reply_to.id,
      sender_id:   reply_to.sender_id,
      sender_name: reply_to.sender&.display_name || "Usuário",
      content:     reply_to.content.to_s.truncate(REPLY_PREVIEW_LENGTH)
    }
  end

  private

  # A citação só pode apontar para uma mensagem desta conversa: um reply_to_id
  # forjado vazaria, no broadcast, o conteúdo de uma conversa de outras pessoas.
  def reply_to_must_belong_to_same_match
    return if reply_to_id.blank?
    return if reply_to && reply_to.match_id == match_id

    errors.add(:reply_to, "precisa ser uma mensagem desta conversa")
  end

  def broadcast_message
    payload = {
      message: {
        id:         id,
        match_id:   match_id,
        content:    content,
        sender_id:  sender_id,
        status:     status,
        created_at: created_at.iso8601,
        user_name:  sender.display_name || "Usuário",
        avatar_url: sender.avatar_url || "/assets/avatarfoto.jpg",
        verified:   sender.verified?,
        reply_to:   reply_to_preview
      }
    }

    MatchChannel.broadcast_to(match, payload)
  rescue => e
    Rails.logger.error "[Message#broadcast_message] Falha no broadcast match=#{match_id} error=#{e.class}: #{e.message}"
  end

  def broadcast_deletion
    MatchChannel.broadcast_to(match, { deleted_message_id: id })
  rescue => e
    Rails.logger.error "[Message#broadcast_deletion] Falha no broadcast match=#{match_id} error=#{e.class}: #{e.message}"
  end

  def send_push_notification
    Rails.logger.info "[Message] Enfileirando PushNotificationJob para message=#{id} match=#{match_id}"
    PushNotificationJob.perform_later(id)
  rescue => e
    Rails.logger.error "[Message#send_push_notification] Falha ao enfileirar job message=#{id} error=#{e.class}: #{e.message}"
  end
end
