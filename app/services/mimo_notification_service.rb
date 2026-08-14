# Notifica o destinatário de um Mimo em dois canais:
#   1. Sino de notificações in-app (Notification + NotificationChannel) — mesma
#      convenção usada para curtidas/matches (ver LikesController).
#   2. Push para o dispositivo (Web Push / APNs / FCM) via MimoPushNotificationJob,
#      assíncrono para não atrasar o processamento do webhook do Mercado Pago.
class MimoNotificationService
  def self.call(mimo_transaction:)
    new(mimo_transaction: mimo_transaction).call
  end

  def initialize(mimo_transaction:)
    @mimo_transaction = mimo_transaction
  end

  def call
    create_in_app_notification!
    MimoPushNotificationJob.perform_later(mimo_transaction.id)
    true
  rescue => e
    Rails.logger.error "[MimoNotificationService] Falha ao notificar mimo_transaction=#{mimo_transaction.id}: #{e.class}: #{e.message}"
    false
  end

  private

  attr_reader :mimo_transaction

  def create_in_app_notification!
    notification = Notification.create!(
      recipient: mimo_transaction.receiver,
      actor: mimo_transaction.sender,
      action: "te enviou um Mimo: #{mimo_transaction.mimo_item.name}",
      notifiable: mimo_transaction
    )
    NotificationBroadcastJob.perform_later(notification)
    notification
  end
end
