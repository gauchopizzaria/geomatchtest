class MimoTransaction < ApplicationRecord
  include AASM

  belongs_to :sender,    class_name: "User"
  belongs_to :receiver,  class_name: "User", optional: true
  belongs_to :mimo_item
  belongs_to :payment, optional: true

  monetize :price_cents
  monetize :receiver_value_cents, as: "receiver_value"
  monetize :mp_fee_cents,         as: "mp_fee"
  monetize :platform_fee_cents,   as: "platform_fee"

  validates :price_cents,          presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :receiver_value_cents, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :sender_and_receiver_must_differ
  # Um Mimo tem exatamente um destino: um usuário já cadastrado (receiver) OU
  # um telefone convidado que ainda não tem conta (receiver_phone) — nunca os
  # dois, nunca nenhum.
  validate :exactly_one_recipient

  aasm column: :status do
    state :pending, initial: true
    state :completed
    state :failed
    state :refunded

    event :complete do
      transitions from: :pending, to: :completed
    end

    # Nomeado "mark_failed" (não "fail") para não sombrear o Kernel#fail nas
    # instâncias do model — um gotcha comum de nomear eventos AASM.
    event :mark_failed do
      transitions from: :pending, to: :failed
    end

    event :refund do
      transitions from: :completed, to: :refunded
    end
  end

  scope :completed,       -> { where(status: "completed") }
  scope :sent_by,         ->(user) { where(sender: user) }
  scope :received_by,     ->(user) { where(receiver: user) }
  scope :recent,          -> { order(created_at: :desc) }
  # Convites pagos aguardando alguém se cadastrar com o telefone para resgatar.
  scope :pending_claim,   -> { completed.where(receiver_id: nil).where(claimed_at: nil) }
  scope :for_phone,       ->(phone) { where(receiver_phone: phone) }

  def guest_invite?
    receiver_id.nil? && receiver_phone.present?
  end

  private

  def sender_and_receiver_must_differ
    return if sender_id.nil? || receiver_id.nil?

    errors.add(:receiver_id, "não pode ser o mesmo usuário que enviou o mimo") if sender_id == receiver_id
  end

  def exactly_one_recipient
    has_receiver = receiver_id.present?
    has_phone    = receiver_phone.present?

    if has_receiver == has_phone # ambos true ou ambos false
      errors.add(:base, "informe um destinatário cadastrado (receiver) ou um telefone de convite (receiver_phone), nunca os dois")
    end
  end
end
