# Envio automático do PIX de saque para a chave do usuário.
#
# Até aqui o sistema só movia dinheiro ENTRE as contas da plataforma
# (MpTransferService, Bolsão -> Operacional) e o envio final era manual. Este
# serviço fecha essa lacuna, mas de propósito NÃO fala com nenhum provedor
# diretamente: ele escolhe um adaptador via ENV["PIX_PAYOUT_PROVIDER"].
#
# O motivo é comercial, não técnico: o Mercado Pago não expõe payout PIX para
# conta comum — precisa ser habilitado no contrato (ver
# PixPayout::MercadoPagoAdapter). Enquanto isso não existir, o adaptador
# `manual` mantém o comportamento atual (operador envia o PIX na mão) sem
# quebrar nada, e trocar de provedor depois é trocar uma variável de ambiente.
#
# REGRA INEGOCIÁVEL — idempotência: dinheiro enviado não volta. Uma ordem só é
# criada no provedor se `payout_external_id` ainda estiver vazio, e a coluna tem
# índice único. Qualquer retry (retry_on do job, deploy no meio da execução,
# admin clicando duas vezes) consulta o status em vez de reenviar.
class PixPayoutService
  class ConfigurationError < StandardError; end

  # status:
  #   :succeeded — provedor confirmou que o PIX saiu -> pode dar baixa (mark_paid!)
  #   :pending   — provedor aceitou e ainda processa -> NÃO dar baixa ainda
  #   :failed    — não saiu; o valor continua reservado para nova tentativa
  #   :skipped   — nenhum provedor automático configurado (envio manual)
  Result = Struct.new(:status, :external_id, :raw, :error, keyword_init: true) do
    def succeeded? = status == :succeeded
    def pending?   = status == :pending
    def failed?    = status == :failed
    def skipped?   = status == :skipped
  end

  ADAPTERS = {
    "manual"       => "PixPayout::ManualAdapter",
    "mercado_pago" => "PixPayout::MercadoPagoAdapter"
  }.freeze

  DEFAULT_PROVIDER = "manual".freeze

  def self.call(withdrawal_request)
    new(withdrawal_request).call
  end

  def self.adapter
    key = ENV["PIX_PAYOUT_PROVIDER"].presence || DEFAULT_PROVIDER
    class_name = ADAPTERS[key] ||
                 raise(ConfigurationError, "PIX_PAYOUT_PROVIDER=#{key.inspect} desconhecido — use um de: #{ADAPTERS.keys.join(', ')}")

    class_name.constantize.new
  end

  def initialize(withdrawal_request)
    @withdrawal_request = withdrawal_request
  end

  def call
    return already_requested if withdrawal_request.payout_external_id.present?

    adapter = self.class.adapter
    return skipped(adapter) unless adapter.enabled?

    withdrawal_request.update!(
      payout_provider: adapter.name,
      payout_status: "requested",
      payout_requested_at: Time.current,
      payout_error: nil
    )

    result = adapter.send_pix(
      amount_cents: withdrawal_request.amount_cents,
      pix_key: withdrawal_request.pix_key,
      pix_key_type: withdrawal_request.pix_key_type,
      # A chave de idempotência é o próprio id da solicitação: estável entre
      # tentativas, único por saque. É ela que impede pagamento em dobro mesmo
      # se a resposta do provedor se perder no meio do caminho.
      idempotency_key: withdrawal_request.id,
      description: "Saque GeoMatch #{withdrawal_request.id}"
    )

    persist!(result)
    result
  rescue StandardError => e
    Rails.logger.error "[PixPayoutService] Falha ao enviar PIX do saque #{withdrawal_request.id}: #{e.class}: #{e.message}"
    failure = Result.new(status: :failed, error: "#{e.class}: #{e.message}")
    persist!(failure)
    failure
  end

  private

  attr_reader :withdrawal_request

  # Ordem já criada no provedor: nunca reenvia. Se o adaptador souber consultar,
  # pergunta o status atual; senão trata como ainda em processamento.
  def already_requested
    adapter = self.class.adapter

    result =
      if adapter.respond_to?(:fetch_status)
        adapter.fetch_status(withdrawal_request.payout_external_id)
      else
        Result.new(status: :pending, external_id: withdrawal_request.payout_external_id)
      end

    persist!(result)
    result
  rescue StandardError => e
    Rails.logger.error "[PixPayoutService] Falha ao consultar payout #{withdrawal_request.payout_external_id}: #{e.class}: #{e.message}"
    Result.new(status: :pending, external_id: withdrawal_request.payout_external_id)
  end

  def skipped(adapter)
    Rails.logger.info "[PixPayoutService] Provedor #{adapter.name.inspect} não envia PIX automaticamente — " \
                      "saque #{withdrawal_request.id} aguarda envio manual."
    withdrawal_request.update!(payout_provider: adapter.name, payout_status: "manual")
    Result.new(status: :skipped)
  end

  def persist!(result)
    withdrawal_request.update!(
      payout_status: result.status.to_s,
      payout_external_id: result.external_id.presence || withdrawal_request.payout_external_id,
      payout_error: result.error,
      payout_payload: result.raw
    )
  end
end
