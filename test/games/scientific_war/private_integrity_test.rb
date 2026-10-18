require_relative '../../support/session_runner'
require_relative '../../../games/scientific_war'

game = GameRoomGames::ScientificWar.new
h = NativeRoomHarness.new(game: game, users: %w[Alice Bob Carol])
h.start
storage = HiddenSubmissions::MemoryStorage.new
vault = HiddenSubmissions::Vault.new(storage)
context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'], hidden_submissions: vault)
action = game.legal_actions(h.replay('Bob'), 'Bob').find { |item| item['action'] == 'select' }
h.submit('Bob', action, context: context)
original = storage.read
alternative = h.replay('Bob').state[:hands]['Bob'].find { |card| card != action.fetch('card') }
storage.update do |root|
  root.fetch('entries').each_value do |entry|
    entry['payload']['card'] = alternative if entry['user'] == 'Bob'
  end
end
replay = h.replay('Bob')
fresh = game.build_session_game
fresh.prepare_view(replay, 'Bob', context: context)
commit = replay.history.find { |entry| entry.kind == :commit }
displayed = fresh.history_entries_for_display(replay, 'Bob').find { |entry| entry.kind == :commit }
assert(displayed.text == commit.text, 'An invalid local envelope changed the displayed accepted choice')
storage.update { |root| root.replace(original) }
fresh.prepare_view(replay, 'Bob', context: context)
displayed = fresh.history_entries_for_display(replay, 'Bob').find { |entry| entry.kind == :commit }
assert(displayed.text != commit.text, 'The valid accepted choice did not recover after a damaged local read')
assert(displayed.text.include?(fresh.send(:playing_card_label, action.fetch('card'))), 'Recovered display used the wrong card')
assert(fresh.history_entries_for_display(replay, 'Alice').find { |entry| entry.kind == :commit }.text == commit.text,
  'The private chosen card leaked to the opponent history')

puts 'PASS Scientific War private presentation accepts only a verified committed local card'
