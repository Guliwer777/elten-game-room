# encoding: UTF-8
require_relative '../support/temporary_directory'
require 'tmpdir'
require_relative '../support/ui'
require_relative '../../games/catalog'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/draft_workspace.rb', __dir__)
require source if File.file?(source)
def assert(condition, message)
  raise message unless condition
end
assert(defined?(GameRoomTournaments::DraftWorkspace), 'Brakuje połączenia formularzy z magazynem')
# W teście nie ma natywnej pętli UI; sam worker Tasks.run pochodzi z hosta.
module EltenAPI
  def loop_update
    Thread.pass
  end
end

GameRoomTest::TemporaryDirectory.create('tournament-workspace-') do |directory|
  caller_thread = Thread.current
  path_threads = []
  program = Object.new
  program.define_singleton_method(:data_path) { path_threads << Thread.current; directory }
  registry = GameRoomGames::CATALOG
  user = 'Alice'
  alerts = []
  workspace = GameRoomTournaments::DraftWorkspace.new(program: program, registry: registry,
    user: -> { user }, alert: ->(message) { alerts << message }, confirm: ->(*) { true })
  assert(workspace.load == [], 'Nowy magazyn nie jest pusty')
  attributes = { 'name' => 'Lokalny turniej', 'game_id' => 'chess', 'game_options' => registry.build('chess').default_options,
    'format' => 'round_robin', 'rematch' => false }
  saved = workspace.persist(nil, attributes)
  assert(saved['revision'] == 1 && saved['owner'] == 'alice', 'Zapis nie przypisał rewizji i właściciela')
  reopened = GameRoomTournaments::DraftWorkspace.new(program: program, registry: registry,
    user: -> { user }, alert: ->(message) { alerts << message }, confirm: ->(*) { true })
  assert(reopened.load == [saved], 'Nowa instancja nie odtworzyła szkicu')
  changed = reopened.persist(saved, attributes.merge('name' => 'Zmieniony'))
  assert(changed['revision'] == 2 && reopened.load.first['name'] == 'Zmieniony', 'Edycja nie zapisała nowej rewizji')
  assert(reopened.remove(changed) && reopened.load.empty?, 'Usuwanie nie trafiło do magazynu')
  assert(alerts.empty?, 'Poprawne operacje zgłosiły błąd')
  assert(!path_threads.empty? && path_threads.none? { |thread| thread.equal?(caller_thread) }, 'Dostęp do dysku wykonano na wątku UI')
end
puts 'PASS integracja trwałego zapisu, odtworzenia, edycji i usuwania na workerze hosta'

GameRoomTest::TemporaryDirectory.create('tournament-workspace-errors-') do |directory|
  program = Object.new
  program.define_singleton_method(:data_path) { directory }
  user = 'Alice'
  messages = []
  workspace = GameRoomTournaments::DraftWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: -> { user }, alert: ->(message) { messages << message }, confirm: ->(*) { true })
  attrs = { 'name' => 'Pierwszy', 'game_id' => 'chess', 'game_options' => {} }
  saved = workspace.persist(nil, attrs)
  newer = workspace.persist(saved, attrs.merge('name' => 'Nowszy'))
  assert(workspace.persist(saved, attrs.merge('name' => 'Stary')).nil?, 'Konflikt rewizji nadpisał nowszy szkic')
  assert(workspace.load == [newer] && messages.last.include?('another window'), 'Konflikt zgubił szkic lub komunikat')
  user = 'Bob'
  assert(workspace.load.nil? && workspace.persist(nil, attrs).nil? && workspace.remove(newer).nil?, 'Stare okno działa po zmianie konta')
  assert(messages.last.include?('account changed'), 'Nie wyjaśniono zmiany konta')
  user = 'Alice'
  assert(workspace.load == [newer], 'Zmiana konta zmodyfikowała stary magazyn')
  assert(workspace.persist(nil, attrs.merge('name' => '')).nil?, 'Nieprawidłowy szkic nie został odrzucony')
  assert(messages.last.include?('tournament name'), 'Walidacja nie ma czytelnego komunikatu')
  path = File.join(directory, Dir.children(directory).find { |name| name.end_with?('.json') } || raise('Brakuje pliku szkicu'))
  File.binwrite(path, '{bad json')
  assert(workspace.load.nil? && workspace.persist(nil, attrs).nil?, 'Korupcja została uznana za pustą listę')
  assert(File.binread(path) == '{bad json' && messages.last.include?('damaged'), 'Uszkodzony plik nadpisano lub ukryto błąd')
end
puts 'PASS konflikty, zmiana konta, walidacja i uszkodzony magazyn bez utraty danych'
