# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
source = File.expand_path('../../lib/tournaments/hub.rb', __dir__)
require source if File.file?(source)
assert(defined?(GameRoomTournaments::Hub), 'Brak Hub')
T = TournamentLocalHubTest
Form.prepend(T::Script)

program = Object.new
program.define_singleton_method(:data_path) { raise 'I/O przy wejściu' }
args = T.args(program: program)
hub = GameRoomTournaments::Hub.new(**args)
T.script(->(form) {
  assert(form.is_a?(GameRoomUI::Form), 'Nie użyto wspólnego Form')
  assert(form.fields.first.text.include?('No invitations or matches'), 'Brak ograniczeń')
  assert(form.accept_button.nil?, 'Enter nie może wybierać trybu')
  assert(form.fields.grep(Button).map(&:label) == ['Local tournament drafts', 'Local test — this computer only', 'Back'], 'Błędny wybór trybów')
  form.cancel_button.trigger(:press)
}) { hub.run }
hub.run
puts 'PASS Hub: jawny wybór, własny Form, brak I/O, Cancel i jednorazowy run'

calls = []
T.replace(GameRoomTournaments::DraftWorkspace, :new, ->(**values) {
  calls << values
  Object.new.tap { |child| child.define_singleton_method(:run) {} }
}) do
  T.script(->(form) {
    form.index = 1
    T.button(form, 'Local tournament drafts').trigger(:press)
    assert(form.index == 1, 'Powrót zgubił fokus')
    form.cancel_button.trigger(:press)
  }) { GameRoomTournaments::Hub.new(**args).run }
end
assert(calls == [args], 'DraftWorkspace nie dostał tych samych parametrów')
puts 'PASS Hub: DraftWorkspace z niezmienionymi parametrami'

owner, messages, opened = 'RealOwner', [], []
args = args.merge(user: -> { owner }, alert: ->(message) { messages << message })
T.replace(GameRoomTournaments::LocalTestHub, :new, ->(**values) {
  opened << values
  Object.new.tap { |child| child.define_singleton_method(:run) { owner = 'OtherOwner' } }
}) do
  hub = GameRoomTournaments::Hub.new(**args)
  T.script(->(form) {
    T.button(form, 'Local test — this computer only').trigger(:press)
    owner = 'RealOwner'
    hub.run
    T.button(form, 'Local test — this computer only').trigger(:press)
    form.cancel_button.trigger(:press)
  }) { hub.run }
end
assert(opened == [args] && messages.any? { |message| message.include?('account changed') }, 'Hub przepiął okno po zmianie ownera')
puts 'PASS Hub: parametry LocalTestHub, zmiana konta w potomku zatrzaskuje całe wejście'
