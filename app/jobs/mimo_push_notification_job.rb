require "stringio"

# Push (dispositivo) para quem recebeu um Mimo — mesma estrutura de 3 canais de
# PushNotificationJob (Web Push / APNs / FCM), mantida separada porque é
# indexada por MimoTransaction, não por Message. O projeto ainda não tem uma
# abstração compartilhada para "enviar push nos 3 canais"; até que exista,
# replicar o padrão já estabelecido é mais simples do que introduzir uma.
class MimoPushNotificationJob < ApplicationJob
  queue_as :default

  def perform(mimo_transaction_id)
    mimo_transaction = MimoTransaction.find_by(id: mimo_transaction_id)
    return unless mimo_transaction

    recipient = mimo_transaction.receiver
    return unless recipient

    title = mimo_transaction.sender.display_name
    body  = "te enviou um Mimo: #{mimo_transaction.mimo_item.name} 🎁"
    url   = "/meu-perfil"

    # Os três canais são completamente independentes — falha em um não afeta os outros.
    send_web_push(recipient, mimo_transaction_id, title, body, url)
    send_apns(recipient, mimo_transaction_id, title, body, url)
    send_fcm(recipient, mimo_transaction_id, title, body, url)
  end

  private

  # ── Canal 1: Web Push (navegadores / PWA) ─────────────────────────
  def send_web_push(recipient, mimo_transaction_id, title, body, url)
    unless ENV["VAPID_PUBLIC_KEY"].present? && ENV["VAPID_PRIVATE_KEY"].present?
      Rails.logger.warn "[MimoPush][WebPush] VAPID keys ausentes — skipping mimo_transaction=#{mimo_transaction_id}"
      return
    end

    subscriptions = recipient.push_subscriptions
    return if subscriptions.empty?

    payload = { title: title, body: body, data: { path: url, app: "GeoMatch" }, tag: "mimo-#{mimo_transaction_id}" }.to_json
    vapid = {
      subject:     ENV.fetch("VAPID_SUBJECT", "mailto:contato@geomatch.app"),
      public_key:  ENV["VAPID_PUBLIC_KEY"],
      private_key: ENV["VAPID_PRIVATE_KEY"]
    }

    subscriptions.each do |subscription|
      begin
        ::WebPush.payload_send(
          message:      payload,
          endpoint:     subscription.endpoint,
          p256dh:       subscription.p256dh,
          auth:         subscription.auth,
          vapid:        vapid,
          ssl_timeout:  10,
          open_timeout: 10,
          read_timeout: 10
        )
      rescue ::WebPush::ExpiredSubscription, ::WebPush::InvalidSubscription
        subscription.destroy
      rescue => e
        Rails.logger.error "[MimoPush][WebPush] Erro — mimo_transaction=#{mimo_transaction_id} subscription=#{subscription.id} error=#{e.class}: #{e.message}"
      end
    end
  end

  # ── Canal 2: APNs (iOS nativo) ────────────────────────────────────
  def send_apns(recipient, mimo_transaction_id, title, body, url)
    return unless recipient.apns_token.present?

    unless ENV["APNS_KEY_P8"].present? && ENV["APNS_KEY_ID"].present? && ENV["APNS_TEAM_ID"].present?
      Rails.logger.warn "[MimoPush][APNs] Variáveis de ambiente ausentes — skipping mimo_transaction=#{mimo_transaction_id}"
      return
    end

    connection = nil
    begin
      raw_env = ENV.fetch("APNS_KEY_P8", "")
      pure_base64 = raw_env
        .gsub(/-----BEGIN PRIVATE KEY-----/, "")
        .gsub(/-----END PRIVATE KEY-----/, "")
        .gsub(/\s+/, "")

      formatted_key = "-----BEGIN PRIVATE KEY-----\n" \
                      "#{pure_base64.scan(/.{1,64}/).join("\n")}\n" \
                      "-----END PRIVATE KEY-----\n"

      p8_key = StringIO.new(formatted_key)

      connection_options = {
        auth_method: :token,
        cert_path:   p8_key,
        key_id:      ENV.fetch("APNS_KEY_ID"),
        team_id:     ENV.fetch("APNS_TEAM_ID")
      }

      connection = if ENV.fetch("APNS_ENV", "production") == "development"
                     Apnotic::Connection.development(connection_options)
                   else
                     Apnotic::Connection.new(connection_options)
                   end

      notification                = Apnotic::Notification.new(recipient.apns_token)
      notification.alert          = { title: title, body: body }
      notification.sound          = "default"
      notification.push_type      = "alert"
      notification.priority       = 10
      notification.custom_payload = { url: url }
      notification.topic          = ENV.fetch("APNS_TOPIC", "br.com.geomatch.app")

      response = connection.push(notification)

      unless response&.ok?
        Rails.logger.error "[MimoPush][APNs] Falha na entrega — mimo_transaction=#{mimo_transaction_id} status=#{response&.status} body=#{response&.body}"
      end
    rescue => e
      Rails.logger.error "[MimoPush][APNs] Erro — mimo_transaction=#{mimo_transaction_id} error=#{e.class}: #{e.message}"
    ensure
      connection&.close
    end
  end

  # ── Canal 3: FCM (Firebase Cloud Messaging — Android nativo) ──────
  def send_fcm(recipient, mimo_transaction_id, title, body, url)
    return unless recipient.fcm_token.present?

    unless ENV["FCM_PROJECT_ID"].present?
      Rails.logger.warn "[MimoPush][FCM] FCM_PROJECT_ID ausente — skipping mimo_transaction=#{mimo_transaction_id}"
      return
    end

    begin
      fcm = FCM.new("firebase-credentials.json", ENV["FCM_PROJECT_ID"])
      message = {
        token:        recipient.fcm_token,
        notification: { title: title, body: body },
        data:         { path: url, url: url }
      }

      response = fcm.send_v1(message)

      unless response[:status_code] == 200
        Rails.logger.error "[MimoPush][FCM] Falha na entrega — mimo_transaction=#{mimo_transaction_id} status=#{response[:status_code]} body=#{response[:body]}"
      end
    rescue => e
      Rails.logger.error "[MimoPush][FCM] Erro — mimo_transaction=#{mimo_transaction_id} error=#{e.class}: #{e.message}"
    end
  end
end
