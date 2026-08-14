# Move saldo entre as duas contas Mercado Pago da própria plataforma:
#   - Conta Operacional: onde o dinheiro dos checkouts (Mimos) cai primeiro.
#   - Conta Bolsão: conta segregada que lastreia o saldo sacável dos usuários,
#     mantendo o dinheiro deles separado do capital de giro da empresa.
#
# A API /v1/transfers do Mercado Pago não é coberta pela gem `mercadopago-sdk`
# (que só expõe preference/payment/refund/etc.), por isso este serviço fala
# HTTP diretamente via Faraday.
class MpTransferService
  class ConfigurationError < StandardError; end

  class TransferError < StandardError
    attr_reader :status, :response_body

    def initialize(message, status: nil, response_body: nil)
      super(message)
      @status = status
      @response_body = response_body
    end
  end

  API_BASE_URL = "https://api.mercadopago.com"

  # direction:
  #   :to_pool        — Operacional -> Bolsão (dinheiro recebido de um Mimo)
  #   :to_operational — Bolsão -> Operacional (ex.: estorno, ajuste)
  def self.call(amount_cents:, direction:, external_reference: nil, description: nil)
    new(
      amount_cents: amount_cents,
      direction: direction,
      external_reference: external_reference,
      description: description
    ).call
  end

  def initialize(amount_cents:, direction:, external_reference: nil, description: nil)
    @amount_cents        = amount_cents.to_i
    @direction           = direction.to_sym
    @external_reference  = external_reference
    @description         = description
  end

  def call
    validate!

    response = connection.post("/v1/transfers") { |req| req.body = build_payload }
    handle_response(response)
  rescue Faraday::Error => e
    raise TransferError.new("Falha de rede ao chamar /v1/transfers: #{e.message}")
  end

  private

  attr_reader :amount_cents, :direction, :external_reference, :description

  def validate!
    raise ArgumentError, "amount_cents deve ser positivo" unless amount_cents.positive?
    raise ArgumentError, "direction inválido: #{direction.inspect}" unless %i[to_pool to_operational].include?(direction)
  end

  def access_token
    ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence ||
      raise(ConfigurationError, "MERCADO_PAGO_ACCESS_TOKEN não configurado")
  end

  def operational_account_id
    ENV["MERCADO_PAGO_OPERATIONAL_ACCOUNT_ID"].presence ||
      raise(ConfigurationError, "MERCADO_PAGO_OPERATIONAL_ACCOUNT_ID não configurado")
  end

  def pool_account_id
    ENV["MERCADO_PAGO_POOL_ACCOUNT_ID"].presence ||
      raise(ConfigurationError, "MERCADO_PAGO_POOL_ACCOUNT_ID não configurado")
  end

  def source_account_id
    direction == :to_pool ? operational_account_id : pool_account_id
  end

  def destination_account_id
    direction == :to_pool ? pool_account_id : operational_account_id
  end

  def build_payload
    {
      source_id: source_account_id,
      destination_id: destination_account_id,
      amount: (amount_cents / 100.0).round(2),
      currency_id: "BRL",
      external_reference: external_reference,
      description: description || "Transferência interna GeoMatch — Mimos"
    }.compact
  end

  def connection
    Faraday.new(url: API_BASE_URL) do |f|
      f.request :json
      f.response :json, content_type: /\bjson$/
      f.headers["Authorization"] = "Bearer #{access_token}"
      f.options.open_timeout = 5
      f.options.timeout      = 15
      f.adapter Faraday.default_adapter
    end
  end

  def handle_response(response)
    return response.body if response.success?

    raise TransferError.new(
      "Mercado Pago retornou #{response.status} em /v1/transfers",
      status: response.status,
      response_body: response.body
    )
  end
end
