# Gerencia o ciclo de vida de uma solicitação de saque (WithdrawalRequest):
# criação (com as regras de negócio de valor mínimo e limite de frequência) e
# as transições administrativas (aprovar / rejeitar / marcar como pago), sempre
# mantendo `user_wallets.pending_withdrawal_cents` consistente com o estado real.
class WithdrawalService
  class InsufficientBalanceError < StandardError; end
  class MinimumAmountError       < StandardError; end
  class RateLimitedError         < StandardError; end
  class InvalidStateError        < StandardError; end
  class MissingPixKeyError       < StandardError; end

  MINIMUM_AMOUNT_CENTS = 5_000 # R$ 50,00
  COOLDOWN             = 24.hours

  # pix_key/pix_key_type são opcionais aqui: se omitidos, usa o que estiver
  # salvo em user_wallets (ver WalletsController#update_pix_key).
  def self.request!(user:, amount_cents:, pix_key: nil, pix_key_type: nil)
    new(user: user, amount_cents: amount_cents, pix_key: pix_key, pix_key_type: pix_key_type).request!
  end

  # Aprovação apenas sinaliza a decisão — o dinheiro continua reservado em
  # pending_withdrawal_cents até o pagamento via PIX ser confirmado (mark_paid!).
  # Dispara o ProcessWithdrawalJob, que executa a movimentação no MP e chama
  # mark_paid! de forma assíncrona.
  def self.approve!(withdrawal_request, admin:)
    raise InvalidStateError, "solicitação não está mais pendente" unless withdrawal_request.may_approve?

    withdrawal_request.update!(processed_by: admin)
    withdrawal_request.approve!
    ProcessWithdrawalJob.perform_later(withdrawal_request.id)
    withdrawal_request
  end

  # Rejeição libera a reserva: o valor volta a ficar disponível na carteira do usuário.
  def self.reject!(withdrawal_request, admin:, reason: nil)
    raise InvalidStateError, "solicitação não está mais pendente" unless withdrawal_request.may_reject?

    ActiveRecord::Base.transaction do
      release_pending_reservation!(withdrawal_request)
      withdrawal_request.update!(processed_by: admin, admin_notes: reason)
      withdrawal_request.reject!
    end
    withdrawal_request
  end

  # Pagamento confirmado (PIX enviado): agora sim debita definitivamente o saldo.
  def self.mark_paid!(withdrawal_request, admin:)
    raise InvalidStateError, "solicitação precisa estar aprovada" unless withdrawal_request.may_mark_paid?

    ActiveRecord::Base.transaction do
      wallet = withdrawal_request.user.wallet
      wallet.with_lock do
        wallet.update!(
          balance_cents: wallet.balance_cents - withdrawal_request.amount_cents,
          pending_withdrawal_cents: wallet.pending_withdrawal_cents - withdrawal_request.amount_cents,
          lifetime_withdrawn_cents: wallet.lifetime_withdrawn_cents + withdrawal_request.amount_cents
        )
      end
      withdrawal_request.update!(processed_by: admin)
      withdrawal_request.mark_paid!
    end
    withdrawal_request
  end

  def self.release_pending_reservation!(withdrawal_request)
    wallet = withdrawal_request.user.wallet
    wallet.with_lock do
      wallet.update!(pending_withdrawal_cents: wallet.pending_withdrawal_cents - withdrawal_request.amount_cents)
    end
  end
  private_class_method :release_pending_reservation!

  def initialize(user:, amount_cents:, pix_key:, pix_key_type: nil)
    @user         = user
    @amount_cents = amount_cents.to_i
    @pix_key      = pix_key
    @pix_key_type = pix_key_type
  end

  def request!
    validate_minimum!
    validate_rate_limit!

    ActiveRecord::Base.transaction do
      wallet = user.wallet || user.create_wallet!
      resolve_pix_key!(wallet)

      # with_lock: garante que duas solicitações simultâneas do mesmo usuário não
      # leiam o mesmo available_balance_cents "velho" e ambas passem no cheque de saldo.
      wallet.with_lock do
        if amount_cents > wallet.available_balance_cents
          raise InsufficientBalanceError, "saldo disponível insuficiente para este saque"
        end

        @withdrawal_request = user.withdrawal_requests.create!(
          amount_cents: amount_cents,
          pix_key: effective_pix_key,
          pix_key_type: effective_pix_key_type
        )

        wallet.update!(pending_withdrawal_cents: wallet.pending_withdrawal_cents + amount_cents)
      end
    end

    withdrawal_request
  end

  private

  attr_reader :user, :amount_cents, :pix_key, :pix_key_type, :withdrawal_request, :effective_pix_key, :effective_pix_key_type

  def resolve_pix_key!(wallet)
    @effective_pix_key      = pix_key.presence || wallet.pix_key
    @effective_pix_key_type = pix_key_type.presence || wallet.pix_key_type

    if effective_pix_key.blank?
      raise MissingPixKeyError, "cadastre uma chave PIX antes de solicitar o saque"
    end
  end

  def validate_minimum!
    if amount_cents < MINIMUM_AMOUNT_CENTS
      raise MinimumAmountError, "o valor mínimo para saque é R$ #{'%.2f' % (MINIMUM_AMOUNT_CENTS / 100.0)}"
    end
  end

  def validate_rate_limit!
    if user.withdrawal_requests.where(created_at: COOLDOWN.ago..).exists?
      raise RateLimitedError, "você já solicitou um saque nas últimas 24 horas"
    end
  end
end
