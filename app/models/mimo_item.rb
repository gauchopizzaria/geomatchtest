class MimoItem < ApplicationRecord
  monetize :price_cents
  monetize :receiver_value_cents, as: "receiver_value"

  has_many :mimo_transactions, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :price_cents, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :receiver_value_cents, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Margem da plataforma (price_cents - receiver_value_cents) não pode ser negativa —
  # a plataforma nunca repassa mais do que cobrou do remetente.
  validate :receiver_value_cannot_exceed_price

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:position, :id) }

  private

  def receiver_value_cannot_exceed_price
    return if receiver_value_cents.nil? || price_cents.nil?

    if receiver_value_cents > price_cents
      errors.add(:receiver_value_cents, "não pode ser maior que o preço cobrado do remetente")
    end
  end
end
