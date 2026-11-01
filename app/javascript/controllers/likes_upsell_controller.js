import { Controller } from "@hotwired/stimulus"

// Painel "N pessoas por perto curtiram você" da tela de Curtidas, para o plano
// que não mostra quem curtiu. Sobe ao tocar num card borrado; fecha tocando
// fora ou com Esc. Sem o painel na página (plano liberado), o link segue normal.
export default class extends Controller {
  static targets = ["sheet"]

  connect() {
    this.onKeydown = (event) => { if (event.key === "Escape") this.close() }
    // Não deixa o painel aberto na "foto" que o Turbo guarda para o voltar
    this.onBeforeCache = () => this.reset()
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
  }

  open(event) {
    if (!this.hasSheetTarget) return
    event.preventDefault()

    clearTimeout(this.hideTimer)
    this.sheetTarget.hidden = false
    // Força o layout do estado fechado antes de abrir — senão o navegador junta
    // as duas mudanças e o painel aparece já aberto, sem a animação de subida.
    void this.sheetTarget.offsetHeight
    this.sheetTarget.classList.add("is-open")
    document.addEventListener("keydown", this.onKeydown)
  }

  close() {
    if (!this.hasSheetTarget) return

    this.sheetTarget.classList.remove("is-open")
    document.removeEventListener("keydown", this.onKeydown)
    this.hideTimer = setTimeout(() => { this.sheetTarget.hidden = true }, 300)
  }

  reset() {
    if (!this.hasSheetTarget) return
    clearTimeout(this.hideTimer)
    this.sheetTarget.classList.remove("is-open")
    this.sheetTarget.hidden = true
  }
}
