# Catálogo padrão de Mimos (presentes virtuais) — ver app/models/mimo_item.rb.
#
# Arquivo separado de db/seeds.rb (que apaga usuários a cada execução) para
# poder popular/atualizar só o catálogo sem mexer nos dados de teste. Também
# pode ser rodado sozinho: bin/rails runner db/seeds/mimos.rb
#
# receiver_value_cents é só a referência estática exibida no catálogo — o
# crédito real ao destinatário é sempre recalculado em tempo real por
# MimoFeeCalculator (ver MimoPaymentService/MimoWalletPaymentService).
MIMO_ITEMS = [
  { name: "Taça de Vinho",        price_cents:  8_000, icon: "🍷",  position: 1, description: "Um brinde especial para começar a conversa." },
  { name: "Prato de Degustação",  price_cents: 15_000, icon: "🍽️", position: 2, description: "Uma seleção de sabores para compartilhar." },
  { name: "Garrafa de Champagne", price_cents: 25_000, icon: "🍾",  position: 3, description: "Para comemorar um match especial." },
  { name: "Jantar Completo",      price_cents: 50_000, icon: "🥘",  position: 4, description: "O Mimo mais generoso: um jantar completo de presente." }
].freeze

puts "Cadastrando catálogo padrão de Mimos..."

MIMO_ITEMS.each do |attrs|
  item = MimoItem.find_or_initialize_by(name: attrs[:name])
  item.assign_attributes(
    description: attrs[:description],
    icon: attrs[:icon],
    position: attrs[:position],
    price_cents: attrs[:price_cents],
    receiver_value_cents: MimoFeeCalculator.call(attrs[:price_cents]).receiver_value_cents,
    active: true
  )
  item.save!
  puts "  - #{item.name} (#{item.price.format})"
end

puts "Catálogo de Mimos populado: #{MimoItem.active.count} itens ativos."
