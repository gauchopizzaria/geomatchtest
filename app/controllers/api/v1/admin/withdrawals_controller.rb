module Api
  module V1
    module Admin
      # GET   /api/v1/admin/withdrawals
      # PATCH /api/v1/admin/withdrawals/:id/approve
      # PATCH /api/v1/admin/withdrawals/:id/reject
      # PATCH /api/v1/admin/withdrawals/:id/mark_paid
      #
      # Sem estes endpoints uma WithdrawalRequest nascia `pending` e nunca saía
      # de lá: o valor ficava reservado na carteira do usuário para sempre e o
      # PIX nunca acontecia, porque WithdrawalService.approve! não era chamado
      # de lugar nenhum da aplicação.
      #
      # ATENÇÃO — a perna final (enviar o PIX para a chave do usuário) continua
      # manual: ProcessWithdrawalJob só move o dinheiro entre as contas da
      # própria plataforma (Bolsão -> Operacional) e dá baixa no ledger. Ver o
      # comentário no topo daquele job.
      class WithdrawalsController < BaseController
        ITEMS_PER_PAGE = 20

        def index
          base = WithdrawalRequest.includes(:user).recent
          base = base.where(status: params[:status]) if params[:status].present?

          page  = [ params[:page].to_i, 1 ].max
          total = base.count
          requests = base.offset((page - 1) * ITEMS_PER_PAGE).limit(ITEMS_PER_PAGE)

          render json: {
            withdrawals: requests.map { |wr| serialize(wr) },
            pagination: {
              current_page: page,
              total_pages: [ (total / ITEMS_PER_PAGE.to_f).ceil, 1 ].max,
              total_count: total
            },
            stats: WithdrawalRequest.group(:status).count
          }
        end

        # Aprova e enfileira o ProcessWithdrawalJob (movimentação + baixa).
        def approve
          withdrawal = WithdrawalRequest.find(params[:id])
          WithdrawalService.approve!(withdrawal, admin: current_api_user)
          render json: serialize(withdrawal.reload)
        end

        # Devolve o valor reservado ao saldo disponível do usuário.
        def reject
          withdrawal = WithdrawalRequest.find(params[:id])
          WithdrawalService.reject!(withdrawal, admin: current_api_user, reason: params[:reason])
          render json: serialize(withdrawal.reload)
        end

        # Baixa manual, para quando o PIX foi enviado por fora do sistema.
        def mark_paid
          withdrawal = WithdrawalRequest.find(params[:id])
          WithdrawalService.mark_paid!(withdrawal, admin: current_api_user)
          render json: serialize(withdrawal.reload)
        end

        private

        def serialize(withdrawal)
          {
            id: withdrawal.id,
            status: withdrawal.status,
            amount_cents: withdrawal.amount_cents,
            amount_formatted: withdrawal.amount.format,
            pix_key: withdrawal.pix_key,
            pix_key_type: withdrawal.pix_key_type,
            user: {
              id: withdrawal.user_id,
              email: withdrawal.user.email,
              username: withdrawal.user.username
            },
            admin_notes: withdrawal.admin_notes,
            created_at: withdrawal.created_at,
            processed_at: withdrawal.processed_at
          }
        end

        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Solicitação de saque não encontrada." }, status: :not_found
        end

        rescue_from WithdrawalService::InvalidStateError do |e|
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
    end
  end
end
