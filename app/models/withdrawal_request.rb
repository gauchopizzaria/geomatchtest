class WithdrawalRequest < ApplicationRecord
  include AASM

  belongs_to :user
  belongs_to :processed_by, class_name: "User", optional: true

  monetize :amount_cents

  validates :amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }

  # Não permite solicitar mais do que o usuário realmente tem disponível na carteira
  # (saldo total menos o que já está reservado em outras solicitações pendentes).
  # on: :create — depois de criada, a própria reserva desta solicitação já está
  # contabilizada em pending_withdrawal_cents; reavaliar em updates posteriores
  # (ex.: WithdrawalService#approve! fazendo update!(processed_by:)) geraria um
  # falso positivo, contando a reserva da própria solicitação contra ela mesma.
  validate :amount_does_not_exceed_available_balance, on: :create

  aasm column: :status do
    state :pending, initial: true
    state :approved
    state :rejected
    state :paid

    event :approve do
      transitions from: :pending, to: :approved
    end

    event :reject do
      transitions from: :pending, to: :rejected
    end

    event :mark_paid do
      transitions from: :approved, to: :paid, after: Proc.new { touch(:processed_at) }
    end
  end

  scope :recent, -> { order(created_at: :desc) }

  private

  def amount_does_not_exceed_available_balance
    return if amount_cents.nil? || user.nil?

    wallet = user.wallet
    available = wallet ? wallet.available_balance_cents : 0

    if amount_cents > available
      errors.add(:amount_cents, "excede o saldo disponível na carteira")
    end
  end
end
