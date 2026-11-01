import { Controller } from "@hotwired/stimulus"

// Olho aberto/fechado do card "Minha Carteira" (/meu-perfil): mostra ou oculta
// o saldo.
//
// A escolha fica num cookie (e não no localStorage) porque o servidor lê o
// cookie e já desenha o card no estado certo — com localStorage o valor
// apareceria de relance a cada abertura da tela até o JS rodar, justamente o
// que quem escolheu ocultar não quer. O cookie também é compartilhado pelo
// WKWebView do app iOS.
const COOKIE_NAME = "hide_wallet_balance"
const ONE_YEAR = 60 * 60 * 24 * 365

export default class extends Controller {
  static targets = ["button"]
  static values = { hidden: Boolean }

  toggle() {
    this.hiddenValue = !this.hiddenValue
    this.persist()
  }

  // Chamado no connect e a cada mudança: mantém classe e rótulo em sincronia.
  hiddenValueChanged() {
    this.element.classList.toggle("is-balance-hidden", this.hiddenValue)

    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-label", this.hiddenValue ? "Mostrar saldo" : "Ocultar saldo")
    }
  }

  persist() {
    const secure = window.location.protocol === "https:" ? "; Secure" : ""
    document.cookie = this.hiddenValue
      ? `${COOKIE_NAME}=1; path=/; max-age=${ONE_YEAR}; SameSite=Lax${secure}`
      : `${COOKIE_NAME}=; path=/; max-age=0; SameSite=Lax${secure}`
  }
}
