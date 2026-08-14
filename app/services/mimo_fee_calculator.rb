# Calcula como o valor bruto de um Mimo (o que o remetente paga) é dividido
# entre a taxa do Mercado Pago, a margem da plataforma e o valor líquido
# creditado na carteira do destinatário.
#
# Serviço puro — sem I/O, sem persistência. Recebe centavos, devolve centavos.
# Isolado para que a fórmula de taxas possa ser testada e ajustada num único
# lugar, sem tocar em MimoPaymentService ou nos models.
class MimoFeeCalculator
  MP_FEE_RATE       = BigDecimal("0.0499") # 4.99% — taxa de processamento do Mercado Pago
  PLATFORM_FEE_RATE = BigDecimal("0.08")   # 8%    — margem da plataforma GeoMatch

  Breakdown = Struct.new(
    :gross_cents, :mp_fee_cents, :platform_fee_cents, :receiver_value_cents,
    keyword_init: true
  )

  def self.call(gross_cents, apply_mp_fee: true)
    new(gross_cents, apply_mp_fee: apply_mp_fee).call
  end

  def initialize(gross_cents, apply_mp_fee: true)
    @gross_cents  = gross_cents.to_i
    @apply_mp_fee = apply_mp_fee
  end

  def call
    raise ArgumentError, "gross_cents deve ser positivo" unless @gross_cents.positive?

    # Pagamento com saldo interno da carteira não passa pelo Mercado Pago —
    # não há taxa de processamento de cartão/Pix a repassar (ver MimoWalletPaymentService).
    mp_fee       = @apply_mp_fee ? round_cents(@gross_cents * MP_FEE_RATE) : 0
    platform_fee = round_cents(@gross_cents * PLATFORM_FEE_RATE)
    receiver_value = @gross_cents - mp_fee - platform_fee

    Breakdown.new(
      gross_cents: @gross_cents,
      mp_fee_cents: mp_fee,
      platform_fee_cents: platform_fee,
      receiver_value_cents: receiver_value
    )
  end

  private

  # Arredondamento bancário (round-half-up) sobre BigDecimal — evita o erro de
  # ponto flutuante de multiplicar Integer por Float diretamente.
  def round_cents(value)
    value.round(0, BigDecimal::ROUND_HALF_UP).to_i
  end
end
