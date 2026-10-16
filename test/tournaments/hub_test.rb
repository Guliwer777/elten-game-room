# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../../lib/tournaments/hub'
GameRoomLocalization.boot(settings: {'interface_language'=>'en','known_languages'=>['en']})
T = TournamentLocalHubTest
G = GameRoomTournaments
Form.prepend(T::Script)

program = Object.new
program.define_singleton_method(:data_path) { raise 'I/O while opening the hub' }
workspace = Object.new
workspace.define_singleton_method(:actor) { 'RealOwner' }
workspace.define_singleton_method(:mode_label) { 'Shared tournaments' }
reads = 0
workspace.define_singleton_method(:load) do
  reads += 1
  {'announcements' => [], 'diagnostics' => {}}
end
%i[join withdraw set_partner edit_tournament delete_tournament].each { |name| workspace.define_singleton_method(name) { |*_| raise 'Unexpected server mutation' } }
args = T.args(program: program).merge(workspace_factory: -> { workspace })
hub = G::Hub.new(**args)
T.script(->(form) {
  assert(form.is_a?(GameRoomUI::Form), 'Missing shared accessible form')
  assert(form.fields.grep(ListBox).map(&:header) == ['Tournaments', 'Show tournaments'], 'The hub must open the directory directly')
  assert(form.index == 0, 'The tournament list must receive initial focus')
  assert(!form.fields.grep(Button).map(&:label).include?('Tournament list'), 'Obsolete intermediate menu is exposed')
  form.cancel_button.trigger(:press)
}) { hub.run }
hub.run
assert(reads == 1, 'Reopening a finished hub repeated the directory request')
puts 'PASS shared hub: direct accessible directory, one initial read, one run and Back'

calls = []
T.replace(G::PublicScreen, :new, ->(**values) {
  calls << values
  Object.new.tap { |child| child.define_singleton_method(:run) {} }
}) do
  hub = G::Hub.new(**args.merge(mine: true))
  T.script { hub.run; hub.run }
end
assert(calls.one? && calls.first[:actor] == 'RealOwner' && calls.first[:program].equal?(program) && calls.first[:mine], 'Wrong account, program or initial view passed to the list')
assert(calls.first[:load].call['announcements'].empty? && reads == 2, 'The directory callback does not use the injected workspace')
puts 'PASS shared hub passes the signed-in account, workspace and requested initial view'

owner, messages, opened = 'RealOwner', [], []
args = args.merge(user: -> {owner}, alert: ->(message) {messages << message})
T.replace(G::PublicScreen, :new, ->(**values) {
  opened << values
  Object.new.tap do |child|
    child.define_singleton_method(:run) do
      owner = 'OtherOwner'
      values.fetch(:create).call
      values.fetch(:recover).call
      owner = 'RealOwner'
      values.fetch(:create).call
      values.fetch(:recover).call
    end
  end
}) do
  hub = G::Hub.new(**args)
  T.script { hub.run }
end
assert(opened.one? && messages.size == 4 && messages.all? {|message| message.include?('account changed')}, 'An account change did not latch the old view')
puts 'PASS shared hub rejects stale account actions even after the old account returns'
