# encoding: UTF-8
# Adapter wyłącznie brakującego domyślnego komunikatu assert na obiekcie main.
# Oryginalny plik i wszystkie jego warunki wykonują się bez edycji.
require_relative '../support/tournament_ft2b1_ui_probe'
def self.assert(value, message = 'Asercja niezmienionej regresji R01')
  super(value, message)
end
require_relative 'ft2b1_catalog_corruption_test'
