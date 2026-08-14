require "openssl"

# Recebe as notificações do Mercado Pago. O MP usa DOIS formatos diferentes e o
# app precisa aceitar os dois — quando o `notification_url` é declarado na
# preferência (é o caso de MimoPaymentService e WalletDepositService), o MP
# manda predominantemente o formato IPN legado, que NÃO tem corpo:
#
#   1) Webhook v2 — corpo JSON:
#      { "type": "payment", "action": "payment.updated", "data": { "id": "123" } }
#   2) Webhook v2 — por query string: ?type=payment&data.id=123  (corpo vazio)
#   3) IPN legado  — por query string: ?topic=payment&id=123     (corpo vazio)
#
# Nos casos 2 e 3 o corpo chega vazio: o payload precisa ser montado a partir da
# query string, senão `WebhookEvent` (que valida `payload` presence) rejeita um
# `{}` com RecordInvalid → 500 → o MP reenvia indefinidamente e o pagamento
# nunca é conciliado. Era exatamente esse o caminho do depósito via PIX.
module Webhooks
  class MercadoPagoController < ActionController::Base
    protect_from_forgery with: :null_session

    def create
      payload_hash = build_payload

      event = WebhookEvent.create!(
        source: "mercadopago",
        external_id: extract_external_id(payload_hash),
        topic: extract_topic(payload_hash),
        action: extract_action(payload_hash),
        payload: payload_hash,
        status: "pending",
        attempts: 0
      )

      ::MercadoPago::WebhookService.call(event: event)

      render json: { id: event.id }, status: :accepted
    rescue JSON::ParserError
      render json: { error: "invalid_json" }, status: :bad_request
    rescue MercadoPagoSignatureError
      render json: { error: "invalid_signature" }, status: :unauthorized
    rescue ActiveRecord::RecordInvalid => e
      # Não deveria mais acontecer (build_payload nunca devolve vazio), mas se
      # acontecer precisa aparecer no log com o payload real — silenciar aqui foi
      # o que escondeu a falha do primeiro depósito.
      Rails.logger.error "[MercadoPagoWebhook] Falha ao registrar evento: #{e.message} " \
                         "query=#{request.query_parameters.inspect} body=#{request.raw_post.to_s.truncate(500)}"
      render json: { error: "invalid_event" }, status: :bad_request
    end

    private

    class MercadoPagoSignatureError < StandardError; end

    def parsed_body
      raw = request.raw_post.to_s
      return {} if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : { "body" => parsed }
    end

    # Sempre devolve um Hash não-vazio — ver comentário no topo da classe.
    def build_payload
      body = parsed_body
      return body if body.present?

      query = request.query_parameters.to_h
      return query if query.present?

      { "received_at" => Time.current.iso8601, "note" => "notificação sem corpo e sem query string" }
    end

    # Cuidado com `params`: `params[:action]` é sempre o nome da action do
    # controller ("create"), nunca o `action` do Mercado Pago — por isso a query
    # string é lida via `request.query_parameters`, que só contém o que veio na URL.
    def query_param(key)
      request.query_parameters[key].presence&.to_s
    end

    def extract_external_id(payload_hash)
      # Webhook v2 (corpo JSON): o id do pagamento vive em data.id.
      from_body = payload_hash.dig("data", "id")
      return from_body.to_s if from_body.present?

      # Webhook v2 por query string: o Rails NÃO aninha "data.id"; a chave é literal.
      from_query = query_param("data.id") || query_param("data_id")
      return from_query if from_query.present?

      # IPN legado (?topic=payment&id=123). O "id" do topo do corpo v2 é o id da
      # NOTIFICAÇÃO, não do pagamento — por isso só vale quando não há "data".
      return payload_hash["id"].to_s if payload_hash["data"].blank? && payload_hash["id"].present?

      query_param("id")
    end

    def extract_topic(payload_hash)
      payload_hash["type"].presence ||
        payload_hash["topic"].presence ||
        query_param("type") ||
        query_param("topic")
    end

    def extract_action(payload_hash)
      payload_hash["action"].presence || query_param("action")
    end
  end
end
