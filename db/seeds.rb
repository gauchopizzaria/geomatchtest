# db/seeds.rb

# Certifique-se de que a gem 'faker' está incluída no seu Gemfile (group :development, :test)
# e que você executou 'bundle install'.

require 'faker'
require 'open-uri' # Necessário para baixar a imagem da URL

# 1. Limpar dados existentes para garantir um estado limpo para o teste
puts "Limpando dados existentes..."

# Limpar tabelas dependentes primeiro para evitar erros de chave estrangeira
begin
  Notification.destroy_all
  Message.destroy_all
  Match.destroy_all
  Like.destroy_all
  Location.destroy_all
  Profile.destroy_all
  User.destroy_all
rescue NameError => e
  puts "AVISO: Um ou mais modelos não foram encontrados. Certifique-se de que os modelos estão definidos. Erro: #{e.message}"
end

puts "Dados existentes limpos."

# 2. Configurações de Localização e Foto
# Coordenadas aproximadas de Itabuna, Bahia
ITABUNA_LAT = -14.78
ITABUNA_LON = -39.27
# URL de uma imagem de placeholder (substitua pela sua imagem de teste)
PLACEHOLDER_IMAGE_URL = "https://placehold.co/300x300/png"

puts "Criando 50 usuários de teste localizados em Itabuna/BA..."

50.times do |i|
  # Senha padrão para todos os usuários de teste
  password = "password123"

  # Geração de coordenadas geográficas próximas a Itabuna (com variação de +/- 0.05 graus )
  latitude = ITABUNA_LAT + rand(-0.05..0.05)
  longitude = ITABUNA_LON + rand(-0.05..0.05)

  # Criação do Usuário
  user = User.create!(
    email: Faker::Internet.unique.email,
    username: Faker::Internet.unique.username(specifier: 5..15),
    password: password,
    password_confirmation: password,
    gender: ['Male', 'Female', 'Other'].sample,
    birthdate: Faker::Date.birthday(min_age: 18, max_age: 65),
    latitude: latitude,
    longitude: longitude,
    bio: Faker::Lorem.paragraph(sentence_count: 3),
    hobbies: Faker::Lorem.words(number: 5).join(', '),
    interested_in: ['Male', 'Female', 'Both'].sample,
    share_location: true,
    created_at: Time.now,
    updated_at: Time.now
  )

  # 3. Anexar Foto de Perfil Única (Active Storage)
  # NOTA: Assumindo que o anexo se chama :avatar. Se for outro nome (ex: :profile_picture),
  # substitua 'avatar' abaixo.
  begin
    downloaded_image = URI.open(PLACEHOLDER_IMAGE_URL)
    user.avatar.attach(io: downloaded_image, filename: "avatar_#{i+1}.png", content_type: 'image/png')
    user.save!
  rescue => e
    puts "AVISO: Falha ao anexar a imagem para o usuário #{user.email}. Verifique a configuração do Active Storage e a URL da imagem. Erro: #{e.message}"
  end

  puts "Usuário #{i + 1}: #{user.email} criado em Lat: #{'%.4f' % latitude}, Lon: #{'%.4f' % longitude}."
end

puts "População de dados concluída. 50 usuários de teste criados e localizados em Itabuna/BA."

# 4. Cupom de primeiro acesso
puts "Criando cupom 'PRIMEIROACESSO'..."
Coupon.find_or_create_by!(code: 'PRIMEIROACESSO') do |coupon|
  coupon.description   = 'Acesso de 1 mês aos recursos Plus e Gold para novos usuários.'
  coupon.discount_type = 'free_access'
  coupon.duration_days = 30
  coupon.plan_codes    = ['plus', 'gold']
  coupon.usage_limit   = 0 # 0 = ilimitado; a restrição de uso único por usuário é garantida pelo UserCoupon
  coupon.active        = true
end
puts "Cupom 'PRIMEIROACESSO' criado/verificado."

# 5. Catálogo de Mimos (presentes virtuais) — arquivo à parte, ver db/seeds/mimos.rb
load Rails.root.join("db", "seeds", "mimos.rb")
