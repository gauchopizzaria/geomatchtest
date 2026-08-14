class WalletReconciliation < ApplicationRecord
  belongs_to :user_wallet
  belongs_to :reconciled_by, class_name: "User", optional: true

  monetize :expected_balance_cents
  monetize :actual_balance_cents

  # Registro de auditoria — não é uma state machine com regras de negócio,
  # apenas o status do fluxo de revisão manual pela equipe.
  enum :status, { pending: "pending", reviewed: "reviewed", resolved: "resolved" }, default: "pending"

  validates :expected_balance_cents, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :actual_balance_cents,   presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :discrepancy_cents,      presence: true, numericality: { only_integer: true }

  before_validation :calculate_discrepancy

  scope :with_discrepancy, -> { where.not(discrepancy_cents: 0) }
  scope :recent,           -> { order(created_at: :desc) }

  private

  # actual - expected: positivo = carteira tem mais do que o ledger esperava
  # (sobra), negativo = carteira tem menos do que deveria (falta a investigar).
  def calculate_discrepancy
    return if expected_balance_cents.nil? || actual_balance_cents.nil?

    self.discrepancy_cents = actual_balance_cents - expected_balance_cents
  end
end
