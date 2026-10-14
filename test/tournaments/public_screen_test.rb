# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/public_screen.rb', __dir__)
require source if File.file?(source)
assert(defined?(GameRoomTournaments::PublicScreen), 'Brakuje listy ogłoszeń turniejów')
Form.prepend(TournamentPublicUI::Script)
T = TournamentPublicUI

def screen(snapshot, **options)
  args = T.arguments(snapshot, **options).reject { |key, _value| [:publication, :snapshot].include?(key) }
  GameRoomTournaments::PublicScreen.new(**args)
end

row = T.publication
alias_row = row.merge('__id' => 13)
other = T.publication(22, game: 'three_five_eight')
bad = T.publication(44).merge('rules' => '')
initial = T.snapshot([row, alias_row, other, bad], [T.registration(51), T.registration(52, tournament_id: 13),
  T.registration(53, tournament_id: 22, user: 'Obcy')])
before = Marshal.dump(initial)
T.script(lambda do |form|
  list = form.fields.first
  assert(list.options.length == 2, 'Aliasy zduplikowały listę lub wadliwy wpis udaje zaakceptowany')
  assert(list.options.first.include?('Chess') && list.options.first.include?('Łukasz') && list.options.first.include?('1'), 'Brak gry, organizatora lub canonical liczby członków')
  assert(list.instance_variable_get(:@item_keys) == [11, 22], 'Klucze listy nie są ID')
  status = T.field(form, 'Status').text
  assert(status.include?(T::MODE) && status.include?('announcements: 1') && status.include?('registrations: 0'), 'Diagnostyki zniknęły lub backend jest niejawny')
  assert(!status.downcase.include?('public'), 'Lokalny tryb udaje publiczny backend')
  list.index = 1
  assert(form.accept_button.label == 'View tournament', 'Globalny Enter nie jest podglądem')
  form.accept_button.trigger(:press)
  assert(form.index == 0 && list.index == 1, 'Powrót zgubił pole lub ID')
  form.cancel_button.trigger(:press)
end, lambda do |form|
  assert(T.field(form, 'Tournament details').text.include?('Próba 22') && form.accept_button.nil?, 'Podgląd złego ID lub globalny Join')
  form.cancel_button.trigger(:press)
end) { screen(initial).run }
assert(Marshal.dump(initial) == before, 'Lista zmieniła snapshot')
puts 'PASS lista: canonical ID, aliasy, obcy skład, diagnostyki, Enter tylko podgląd'

changed = T.snapshot([row, other.merge('title' => 'Zmieniona etykieta')])
reversed = GameRoomTournaments::Publication::Data.freeze_tree(changed.merge('announcements' => changed['announcements'].reverse))
loads = [initial, reversed, nil, T.snapshot([])]
T.script(lambda do |form|
  list = form.fields.first
  list.index = 1
  form.index = 3
  T.button(form, 'Refresh').trigger(:press)
  assert(list.index == 0 && list.options.first.start_with?('Zmieniona etykieta'), 'Refresh zgubił ID przy zmianie kolejności i etykiet')
  labels = list.options.dup
  T.button(form, 'Refresh').trigger(:press)
  assert(list.index == 0 && list.options == labels && form.index == 3, 'nil odczytu wyczyścił dane lub fokus')
  T.button(form, 'Refresh').trigger(:press)
  assert(list.options.empty?, 'Poprawny pusty snapshot nie wyczyścił listy')
  form.accept_button.trigger(:press)
  form.cancel_button.trigger(:press)
end) { screen(initial, load: -> { loads.shift }).run }
assert(loads.empty?, 'Nie wykonano wszystkich odczytów')
T.script { screen(initial, load: -> { nil }).run }
puts 'PASS refresh: odwrócenie, zmiana etykiety, nil zachowuje ostatni snapshot, pusta lista i początkowy nil'

calls = 0
instance = nil
T.script(lambda do |form|
  form.accept_button.trigger(:press)
  form.cancel_button.trigger(:press)
end, ->(form) { form.cancel_button.trigger(:press) }) do
  instance = screen(initial, load: lambda do
    calls += 1
    instance.run
    initial
  end)
  instance.run
end
assert(calls == 1, 'Ponowne wejście w początkowy load powieliło listę')
puts 'PASS reentry początkowego load nie zamyka i nie powiela listy'
