# app/controllers/notifications_controller.rb
class NotificationsController < ApplicationController
  before_action :authenticate_user!

  def index
    photo_includes = { avatar_attachment: :blob, album_photos_attachments: :blob }

    # 1. Quem te curtiu — só curtidas e matches (Mimo não é curtida) e sem quem
    #    está bloqueado nos dois sentidos: bloquear apaga likes e matches, mas não
    #    as notificações, então elas precisam ser filtradas aqui. Contas banidas
    #    também ficam de fora. Uma entrada por pessoa (a mais recente).
    @notifications = current_user.notifications
      .where(notifiable_type: %w[Like Match])
      .where.not(actor_id: current_user.excluded_user_ids)
      .joins(:actor).merge(User.where(banned_at: nil))
      .includes(actor: photo_includes)
      .order(created_at: :desc)
      .to_a
      .uniq(&:actor_id)

    # 2. Quem VOCÊ curtiu
    @my_likes = Like.where(liker_id: current_user.id)
      .includes(liked: photo_includes)
      .order(created_at: :desc)

    # Estado do coração "curtir de volta" de cada card: quem você já curtiu e,
    # se já deu match, a conversa para onde o coração leva.
    actor_ids = @notifications.map(&:actor_id)
    @liked_back_ids = Like.where(liker_id: current_user.id, liked_id: actor_ids).pluck(:liked_id).to_set
    @matches_by_user = Match.for_user(current_user.id)
                            .where("user_id IN (:ids) OR matched_user_id IN (:ids)", ids: actor_ids)
                            .index_by { |match| match.user_id == current_user.id ? match.matched_user_id : match.user_id }

    # Marca todas como lidas ao visitar a página
    current_user.notifications.unread.update_all(read_at: Time.current)
  end
end
