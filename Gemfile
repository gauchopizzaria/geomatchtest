source "https://rubygems.org"

gem "aasm"
gem "activestorage-cloudinary-service"
gem "aws-sdk-s3", require: false
gem "bootsnap", require: false
gem "cloudinary"
gem "dartsass-rails"
gem "devise"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection"
gem "dotenv-rails", groups: [ :development, :test ]
gem "enumerize"
gem "fiddle"
gem "geocoder"
gem "image_processing", "~> 1.2"
gem "importmap-rails"
gem "jbuilder"
gem "jwt", "~> 2.8"
gem "rack-cors"
gem "jsbundling-rails"
gem "kamal", require: false
gem "kaminari"
gem "letter_opener_web", group: :development
gem "mercadopago-sdk"
gem "money-rails"
# Já vinha no bundle como dependência transitiva (fcm, cloudinary); declarada aqui
# porque MpTransferService a usa diretamente para chamar /v1/transfers do MP.
gem "faraday"
gem "pg", "~> 1.1"
gem "propshaft"
gem "puma", ">= 5.0"
gem "pundit"
gem "rails", "~> 8.1.1"
gem "redis", "~>5.0"
gem "solid_cable"
gem "solid_cache"
gem "solid_queue"
gem "stimulus-rails"
gem "thruster", require: false
gem "turbo-rails"
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "sidekiq-cron"
gem "web-push"
gem "apnotic"
gem "fcm"
gem "google-cloud-vision"

group :development, :test do
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "faker"
  gem "pry-rails"
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "factory_bot_rails"
  gem "rspec-rails"
  gem "selenium-webdriver"
  gem "shoulda-matchers", require: false
  gem "vcr"
  gem "webmock"
end

