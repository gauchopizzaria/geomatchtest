class Payment < ApplicationRecord
  include PaymentStateMachine

  belongs_to :plan, optional: true
  belongs_to :user

  enum :payment_type, {
    plan_purchase:  'plan_purchase',
    one_off_message: 'one_off_message',
    admin_grant:    'admin_grant',       # Cortesia / ajuste manual pelo administrador
    mimo_purchase:  'mimo_purchase',     # Compra de um Mimo (presente virtual) para outro usuário
    wallet_deposit: 'wallet_deposit'     # Adicionar saldo à própria UserWallet (ver WalletDepositService)
  }

  # Nome próprio (não "amount") para não colidir com o método #amount abaixo,
  # que já é a fonte de verdade para plan_purchase/admin_grant.
  monetize :deposit_amount_cents, as: "deposit_amount", allow_nil: true

  # dependent: :nullify — o Payment é o registro financeiro "mestre" da cobrança;
  # nunca deve ser destruído em cascata a partir da limpeza de uma MimoTransaction.
  has_one :mimo_transaction, dependent: :nullify

  # Alias para que CheckoutController#create_one_off_message possa chamar payment.checkout_url
  alias_attribute :checkout_url, :mercado_pago_checkout_url

  scope :latest_first,          -> { order(created_at: :desc) }
  scope :approved,              -> { where(state: 'approved') }

  def amount
    plan&.price
  end

  def apply_premium!(fallback_days: 30)
    effective_days = plan.duration_days.presence || fallback_days

    now = Time.current
    base = [user.premium_until, now].compact.max
    user.update!(premium_until: base + effective_days.days)
  end
end


