# encoding: UTF-8
require_relative '../support/settings_widget'

entry = EltenGameRoom::MAIN_OPTIONS.index('Tournaments')
assert(entry, 'Brakuje wejścia do turniejów w menu Game Roomu')
assert(defined?(GameRoomTournaments::Hub), 'Aplikacja nie ładuje menu modułu turniejów')
app = EltenGameRoom.new
opened = []
labels = {
  'Create a new table' => :show_create_table, 'Join a table' => :show_join_table,
  'Game rules' => :show_rules_library, 'Invitations' => :switch_to_invited_table,
  'Saved games' => :show_saved_games, 'Leaderboards' => :show_leaderboards,
  'Statistics' => :show_statistics, 'Settings' => :show_settings,
  "What's new" => :show_changelog, 'Tournaments' => :show_tournaments
}
labels.each_value { |method| app.define_singleton_method(method) { opened << method } }
EltenGameRoom::MAIN_OPTIONS.each_with_index do |label, index|
  app.send(:open_main_option, index)
  assert(opened.last == labels.fetch(label), "Menu uruchomiło złą akcję: #{label}")
end
assert(EltenGameRoom::MAIN_OPTIONS.last == "What's new", 'Zmieniono położenie ostatniej pozycji menu')

factory = GameRoomTournaments::Hub.method(:new)
received = nil
ran = false
workspace = Object.new
workspace.define_singleton_method(:run) { ran = true }
GameRoomTournaments::Hub.define_singleton_method(:new) do |**options|
  received = options
  workspace
end
begin
  instance = EltenGameRoom.new
  instance.send(:show_tournaments)
  assert(ran && received[:program].equal?(instance), 'Wejście menu nie uruchomiło modułu na własnym programie')
  assert(received[:registry].equal?(EltenGameRoom::GAME_REGISTRY), 'Moduł nie otrzymał rejestru wszystkich gier')
  assert(received[:user].call == Session.name, 'Moduł nie otrzymał bieżącej tożsamości użytkownika')
  assert(received.keys.sort == [:program, :registry, :user, :alert, :confirm].sort, 'Menu przekazało nieuzgodniony kontekst')
  calls = []
  instance.define_singleton_method(:alert) { |message| calls << [:alert, message] }
  instance.define_singleton_method(:confirm) { |message| calls << [:confirm, message]; true }
  received[:alert].call('Komunikat')
  assert(received[:confirm].call('Pytanie'), 'Utracono wynik potwierdzenia')
  assert(calls == [[:alert, 'Komunikat'], [:confirm, 'Pytanie']], 'Callbacki nie należą do bieżącego programu')
ensure
  GameRoomTournaments::Hub.define_singleton_method(:new, factory)
end
puts 'PASS wejście turniejów i niezmienione akcje istniejącego menu'

# Prawdziwe formularze aplikacji, izolowana pętla testowa bez żywego hosta.
# Samo wejście i Cancel nie mogą tworzyć magazynu ani korzystać z sieci.
require_relative '../support/tournament_local_hub'
T = TournamentLocalHubTest
Form.prepend(T::Script)
instance = EltenGameRoom.new
instance.define_singleton_method(:data_path) { raise 'I/O podczas wejścia menu' }
instance.define_singleton_method(:server_tables) { raise 'Sieć podczas wejścia menu' }
T.script(->(form) {
  assert(form.fields.first.header == 'Tournaments', 'Menu nie otworzyło huba')
  assert(form.accept_button.nil?, 'Enter automatycznie wybiera tryb')
  T.button(form, 'Local test — this computer only').trigger(:press)
  form.cancel_button.trigger(:press)
}, ->(form) {
  assert(form.fields.first.header == 'Choose a test participant', 'Nie otwarto jawnego wyboru uczestnika')
  assert(T.field(form, 'Test participant name').text.empty?, 'Podsunięto prawdziwe konto jako aktora')
  form.cancel_button.trigger(:press)
}) { instance.send(:open_main_option, entry) }
puts 'PASS menu → hub → test lokalny → Cancel, bez I/O i sieci'
