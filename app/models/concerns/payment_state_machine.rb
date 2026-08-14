module PaymentStateMachine
  extend ActiveSupport::Concern

  included do
    include AASM

    aasm column: :state do
      state :created, initial: true
      state :pending
      state :approved
      state :rejected
      state :refunded

      event :pending do
        transitions from: %i[created], to: :pending, after: Proc.new { |*args| update_payment_with_mp_payment(*args) }
      end

      event :approve do
        transitions from: %i[created pending], to: :approved, after: Proc.new { |*args| set_approve(*args) }
      end

      event :reject do
        transitions from: %i[created pending], to: :rejected, after: Proc.new { |*args| update_payment_with_mp_payment(*args) }
      end

      event :refund do
        transitions from: %i[approved rejected], to: :refunded, after: Proc.new { |*args| update_payment_with_mp_payment(*args) }
      end
    end
  end

  # mp_payment é opcional: ausente para admin_grant (sem Mercado Pago envolvido)
  def set_approve(mp_payment = {})
    if admin_grant?
      update!(paid_at: Time.current)
      sync_user_plan_from_admin_grant!
    else
      update_payment_with_mp_payment(mp_payment)

      if one_off_message?
        user.add_message_credit!
      elsif mimo_purchase?
        # Nada a fazer aqui: MimoPaymentService.complete! (chamado pelo
        # WebhookService) é quem credita a carteira do destinatário — um
        # Mimo não tem plano/assinatura envolvido.
      elsif wallet_deposit?
        # Nada a fazer aqui: WalletDepositService.complete! (chamado pelo
        # WebhookService) é quem credita o saldo do próprio usuário — um
        # depósito não tem plano/assinatura envolvido.
      else
        sync_user_plan_from_payment!
      end
    end
  end

  def set_refund(mp_payment)
    update_payment_with_mp_payment(mp_payment)
    touch(:paid_at)
    sync_user_plan_from_refund!
  end

  def update_payment_with_mp_payment(mp_payment)
    update!(
      mercado_pago_payment_id: mp_payment["id"]&.to_s,
      mercado_pago_merchant_order_id: mp_payment["order"]&.dig("id")&.to_s,
      mercado_pago_payload: mp_payment
    )
  end

  private

  def sync_user_plan_from_payment!
    user.update!(plan: plan, premium_until: Time.current + plan.duration_days.days)
  end

  # Cortesia do admin: plano Free remove premium, outros recebem acesso indefinido (100 anos)
  def sync_user_plan_from_admin_grant!
    premium_until = plan.name == 'Free' ? nil : 100.years.from_now
    user.update!(plan: plan, premium_until: premium_until)
  end

  def sync_user_plan_from_refund!
    free_plan = Plan.find_by(name: 'Free')
    return if user.plan_id == free_plan.id

    user.update!(plan: free_plan, premium_until: nil)
  end
end


