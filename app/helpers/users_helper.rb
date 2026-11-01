module UsersHelper
  # Faixas de cor da barra "X% completo" em /meu-perfil:
  #   abaixo de 50% -> vermelho (muito incompleto)
  #   50% a 99%     -> laranja  (pela metade)
  #   100%          -> verde    (tudo certo)
  PROFILE_COMPLETION_HALF = 50

  def profile_completion_state_class(percentage)
    if percentage >= 100
      "is-complete"
    elsif percentage >= PROFILE_COMPLETION_HALF
      "is-half"
    else
      "is-low"
    end
  end
end
