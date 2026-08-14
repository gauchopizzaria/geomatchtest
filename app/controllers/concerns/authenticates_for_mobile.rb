# Autenticação dual para endpoints JSON consumidos pelo app mobile nativo:
#   - Bearer JWT (app nativo Android/iOS, sem cookie de sessão)
#   - Sessão Devise (fallback web / Hotwire Native WebView)
#
# Mesmo padrão já usado em UsersController#authenticate_for_location! e
# PushSubscriptionsController#authenticate_for_fcm! — extraído aqui porque
# MimosController e WalletsController precisam dele simultaneamente.
module AuthenticatesForMobile
  extend ActiveSupport::Concern

  included do
    attr_reader :mobile_current_user
  end

  def authenticate_for_mobile!
    auth_header = request.headers["Authorization"]

    if auth_header&.start_with?("Bearer ")
      token   = auth_header.split(" ", 2).last
      payload = JwtService.decode(token)
      @mobile_current_user = User.find(payload[:sub])
    elsif user_signed_in?
      # user_signed_in? só consulta o warden, nunca redireciona — ao contrário de
      # authenticate_user!, que faz negociação de formato e devolveria um 302
      # HTML para /users/sign_in em vez de JSON quando não há sessão nem token.
      @mobile_current_user = current_user
    else
      render json: { error: "Não autenticado" }, status: :unauthorized
    end
  rescue JWT::ExpiredSignature
    render json: { error: "Token expirado" }, status: :unauthorized
  rescue JWT::DecodeError
    render json: { error: "Token inválido" }, status: :unauthorized
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Usuário não encontrado" }, status: :unauthorized
  end
end
