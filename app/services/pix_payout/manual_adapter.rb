module PixPayout
  # Comportamento padrão e atual: o sistema NÃO envia o PIX: o operador envia a
  # partir da Conta Operacional e depois dá baixa (mimos:mark_withdrawal_paid ou
  # PATCH /api/v1/admin/withdrawals/:id/mark_paid).
  #
  # Existe para que "sem provedor automático" seja um estado explícito e testável
  # do sistema, e não um TODO escondido dentro do job.
  class ManualAdapter
    def name = "manual"

    def enabled? = false

    def send_pix(**)
      raise NotImplementedError, "ManualAdapter nunca envia PIX — enabled? é false"
    end
  end
end
