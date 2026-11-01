import { Controller } from "@hotwired/stimulus"

// Abas "Te curtiram" / "Você curtiu" da tela de Curtidas (/notifications).
// Cada aba aponta para um painel (data-panel) e traz o subtítulo do cabeçalho.
export default class extends Controller {
  static targets = ["tab", "panel", "subtitle"]

  select(event) {
    this.show(event.currentTarget.dataset.panel)
  }

  show(name) {
    this.tabTargets.forEach((tab) => {
      const active = tab.dataset.panel === name
      tab.classList.toggle("is-active", active)
      tab.setAttribute("aria-selected", String(active))
      if (active && this.hasSubtitleTarget) this.subtitleTarget.textContent = tab.dataset.subtitle
    })

    this.panelTargets.forEach((panel) => {
      panel.hidden = panel.dataset.panel !== name
    })
  }
}
