MoneyRails.configure do |config|
  config.default_currency = :brl
  config.locale_backend = :i18n

  # "%u %n" = símbolo, espaço, número — a convenção brasileira (R$ 5,00). Sem
  # isto o money gem cola o símbolo no número ("R$5,00"). Os separadores vêm das
  # chaves number.currency.format em config/locales/pt-BR.yml.
  config.default_format = { format: "%u %n" }
end
