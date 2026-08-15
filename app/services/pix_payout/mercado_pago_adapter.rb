module PixPayout
  # Envio de PIX para a chave de um terceiro usando o Mercado Pago.
  #
  # LEIA ANTES DE HABILITAR
  # -----------------------
  # O Mercado Pago NÃO libera payout PIX para conta comum. A API pública cobre
  # receber pagamentos; enviar dinheiro para a chave de outra pessoa exige
  # habilitação comercial (produto de pagamentos em massa / money out) e o
  # contrato exato — endpoint, campos e formato do destino — é definido pelo MP
  # para cada conta. Por isso:
  #
  #   * o adaptador só liga com PIX_PAYOUT_ENABLED=true (nunca por acidente);
  #   * o endpoint vem de ENV, para ajustar ao que o MP habilitar sem mexer no
  #     código nem fazer deploy;
  #   * VALIDE EM SANDBOX antes de produção — aqui sai dinheiro de verdade.
  #
  # A mecânica que realmente importa (idempotência, timeout, classificação de
  # status, tratamento de erro) é independente de provedor e está pronta. Se
  # você escolher outro provedor de payout, copie esta classe, troque
  # #endpoint/#build_payload/#classify e mude PIX_PAYOUT_PROVIDER.
  class MercadoPagoAdapter
    API_BASE_URL     = "https://api.mercadopago.com".freeze
    DEFAULT_ENDPOINT = "/v1/payouts".freeze

    # Como o MP nomeia os tipos de chave PIX no destino.
    PIX_KEY_TYPES = {
      "cpf"    => "CPF",
      "cnpj"   => "CNPJ",
      "email"  => "EMAIL",
      "phone"  => "PHONE",
      "random" => "EVP"
    }.freeze

    def name = "mercado_pago"

    # Dois interruptores: a flag explícita e o token. Faltando qualquer um, o
    # sistema cai no envio manual em vez de estourar erro no meio de um saque.
    def enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["PIX_PAYOUT_ENABLED"]).present? && access_token.present?
    end

    def send_pix(amount_cents:, pix_key:, pix_key_type:, idempotency_key:, description: nil)
      response = connection.post(endpoint) do |req|
        # X-Idempotency-Key: se a resposta se perder e o job repetir, o MP
        # devolve a MESMA ordem em vez de criar uma segunda. É a proteção
        # contra pagar o usuário duas vezes.
        req.headers["X-Idempotency-Key"] = idempotency_key.to_s
        req.body = build_payload(
          amount_cents: amount_cents,
          pix_key: pix_key,
          pix_key_type: pix_key_type,
          description: description,
          idempotency_key: idempotency_key
        )
      end

      build_result(response)
    rescue Faraday::Error => e
      # Falha de rede é ambígua: a ordem PODE ter sido criada. Devolvemos
      # :failed sem external_id, e a idempotência garante que a próxima
      # tentativa não duplique.
      PixPayoutService::Result.new(status: :failed, error: "Falha de rede ao chamar o Mercado Pago: #{e.message}")
    end

    def fetch_status(external_id)
      response = connection.get("#{endpoint}/#{external_id}")
      build_result(response, fallback_external_id: external_id)
    rescue Faraday::Error => e
      PixPayoutService::Result.new(status: :pending, external_id: external_id, error: e.message)
    end

    private

    def access_token
      ENV["MERCADO_PAGO_PAYOUT_ACCESS_TOKEN"].presence || ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence
    end

    def endpoint
      ENV["MERCADO_PAGO_PAYOUT_ENDPOINT"].presence || DEFAULT_ENDPOINT
    end

    def build_payload(amount_cents:, pix_key:, pix_key_type:, description:, idempotency_key:)
      {
        amount: (amount_cents / 100.0).round(2),
        currency_id: "BRL",
        description: description,
        external_reference: idempotency_key.to_s,
        payment_method_id: "pix",
        receiver: {
          pix_key: pix_key,
          pix_key_type: PIX_KEY_TYPES.fetch(pix_key_type.to_s, pix_key_type.to_s.upcase)
        }
      }.compact
    end

    def build_result(response, fallback_external_id: nil)
      body = response.body.is_a?(Hash) ? response.body : {}
      external_id = body["id"]&.to_s || fallback_external_id

      unless response.success?
        return PixPayoutService::Result.new(
          status: :failed,
          external_id: external_id,
          raw: body,
          error: "Mercado Pago retornou #{response.status}: #{body.to_json.truncate(500)}"
        )
      end

      PixPayoutService::Result.new(status: classify(body["status"].to_s), external_id: external_id, raw: body)
    end

    # Conservador de propósito: status desconhecido vira :pending, nunca
    # :succeeded. Dar baixa num saque que não saiu é pior do que deixá-lo aberto.
    def classify(status)
      case status
      when "approved", "released", "paid", "completed", "success" then :succeeded
      when "rejected", "cancelled", "failed", "error"             then :failed
      else :pending
      end
    end

    def connection
      Faraday.new(url: API_BASE_URL) do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.headers["Authorization"] = "Bearer #{access_token}"
        f.options.open_timeout = 5
        f.options.timeout      = 20
        f.adapter Faraday.default_adapter
      end
    end
  end
end
