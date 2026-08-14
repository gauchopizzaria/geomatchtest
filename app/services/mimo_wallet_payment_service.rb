# Envia um Mimo pagando com o saldo já depositado na UserWallet do remetente —
# transferência interna, sem passar pelo Mercado Pago (ver MimoPaymentService
# para o fluxo pago com cartão/Pix).
#
# Só aceita destinatário já cadastrado (`receiver:` obrigatório): não existe
# convite por telefone aqui, pois não há como creditar a carteira de alguém
# sem conta (ver MimoInviteService/receiver_phone em MimoPaymentService).
#
# Débito do remetente + crédito do destinatário + criação da MimoTransaction já
# "completed" acontecem atomicamente dentro de uma única ActiveRecord::Base.transaction,
# com with_lock (SELECT ... FOR UPDATE) nas duas carteiras — mesma técnica de
# locking usada em MimoPaymentService.complete!, para que dois envios/depósitos/
# saques concorrentes nunca leiam um saldo desatualizado.
class MimoWalletPaymentService
  class InsufficientBalanceError < StandardError; end
  class InvalidRecipientError    < StandardError; end
  class ItemUnavailableError     < StandardError; end

  def self.call(sender:, receiver:, mimo_item:, message: nil)
    new(sender: sender, receiver: receiver, mimo_item: mimo_item, message: message).call
  end

  def initialize(sender:, receiver:, mimo_item:, message: nil)
    @sender    = sender
    @receiver  = receiver
    @mimo_item = mimo_item
    @message   = message
  end

  def call
    validate!

    ActiveRecord::Base.transaction do
      debit_sender!
      credit_receiver!
      create_completed_transaction!
    end

    mimo_transaction
  rescue => e
    Rails.logger.error "[MimoWalletPaymentService] Falha ao transferir saldo — sender=#{sender&.id} receiver=#{receiver&.id} error=#{e.class}: #{e.message}"
    raise
  end

  private

  attr_reader :sender, :receiver, :mimo_item, :message, :mimo_transaction

  def fee_breakdown
    # apply_mp_fee: false — não há cobrança de cartão/Pix nesta transferência,
    # só a margem da própria plataforma.
    @fee_breakdown ||= MimoFeeCalculator.call(mimo_item.price_cents, apply_mp_fee: false)
  end

  def validate!
    raise InvalidRecipientError, "informe um destinatário cadastrado para pagar com o saldo da carteira" if receiver.nil?
    raise InvalidRecipientError, "remetente e destinatário não podem ser o mesmo usuário" if sender.id == receiver.id
    raise ItemUnavailableError, "este Mimo não está disponível no momento" unless mimo_item.active?
  end

  def debit_sender!
    wallet = sender.wallet
    raise InsufficientBalanceError, "Você ainda não tem saldo na carteira" if wallet.nil?

    wallet.with_lock do
      if wallet.available_balance_cents < fee_breakdown.gross_cents
        raise InsufficientBalanceError, "Saldo insuficiente para presentear com o saldo da carteira"
      end

      wallet.update!(balance_cents: wallet.balance_cents - fee_breakdown.gross_cents)
    end
  end

  def credit_receiver!
    wallet = receiver.wallet || receiver.create_wallet!

    wallet.with_lock do
      wallet.update!(
        balance_cents: wallet.balance_cents + fee_breakdown.receiver_value_cents,
        lifetime_earned_cents: wallet.lifetime_earned_cents + fee_breakdown.receiver_value_cents
      )
    end
  end

  def create_completed_transaction!
    @mimo_transaction = MimoTransaction.create!(
      sender: sender,
      receiver: receiver,
      mimo_item: mimo_item,
      message: message,
      price_cents: fee_breakdown.gross_cents,
      mp_fee_cents: fee_breakdown.mp_fee_cents,
      platform_fee_cents: fee_breakdown.platform_fee_cents,
      receiver_value_cents: fee_breakdown.receiver_value_cents
    )
    @mimo_transaction.complete!
  end
end
