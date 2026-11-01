module NotificationsHelper
  # "~150 m de você" / "~1,2 km de você": distância APROXIMADA (múltiplos de
  # 50 m) entre quem vê e a outra pessoa. Não aparece se faltar localização de
  # alguém ou se a pessoa estiver invisível / tiver desligado o compartilhamento.
  # suffix: false devolve só "~150 m" (pílula dos cards borrados do plano grátis).
  def approx_distance_from_you(viewer, other, suffix: true)
    return nil if other.invisible? || other.share_location == false
    return nil if [viewer.latitude, viewer.longitude, other.latitude, other.longitude].any?(&:blank?)

    km = Geocoder::Calculations.distance_between(
      [viewer.latitude, viewer.longitude], [other.latitude, other.longitude], units: :km
    )
    meters = ((km * 1000) / 50.0).round * 50

    label =
      if meters < 1000 then "~#{[meters, 50].max} m"
      elsif km < 10    then "~#{('%.1f' % km).tr('.', ',')} km"
      else                  "~#{km.round} km"
      end

    suffix ? "#{label} de você" : label
  end

  # Preço do painel de upgrade: "R$ 49,90/mês" (ou "a cada N meses").
  def plan_price_per_period(plan)
    months = plan.duration_months.to_i
    months <= 1 ? "#{plan.price.format}/mês" : "#{plan.price.format} a cada #{months} meses"
  end

  # Pílula "Ativa agora" dos cards — só para quem está online e não invisível.
  def online_now_label(user)
    return nil unless user.online? && !user.invisible?

    case user.gender
    when "Mulher" then "Ativa agora"
    when "Homem"  then "Ativo agora"
    else               "Online agora"
    end
  end
end
