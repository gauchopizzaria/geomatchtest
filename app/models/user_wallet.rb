class UserWallet < ApplicationRecord
  belongs_to :user

  has_many :wallet_reconciliations, dependent: :destroy

  monetize :balance_cents
  monetize :pending_withdrawal_cents
  monetize :lifetime_earned_cents
  monetize :lifetime_withdrawn_cents

  validates :user_id, uniqueness: true
  validates :balance_cents,             presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :pending_withdrawal_cents,  presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :lifetime_earned_cents,     presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :lifetime_withdrawn_cents,  presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Não é possível ter mais saldo bloqueado em saques do que o saldo total da carteira.
  validate :pending_withdrawal_cannot_exceed_balance

  PIX_KEY_TYPES = %w[cpf cnpj email phone random].freeze
  validates :pix_key_type, inclusion: { in: PIX_KEY_TYPES }, allow_nil: true

  # Saldo realmente livre para uma nova solicitação de saque
  # (o que já está reservado em withdrawal_requests pendentes não conta de novo).
  def available_balance_cents
    balance_cents - pending_withdrawal_cents
  end

  private

  def pending_withdrawal_cannot_exceed_balance
    return if pending_withdrawal_cents.nil? || balance_cents.nil?

    if pending_withdrawal_cents > balance_cents
      errors.add(:pending_withdrawal_cents, "não pode ser maior que o saldo da carteira")
    end
  end
end
