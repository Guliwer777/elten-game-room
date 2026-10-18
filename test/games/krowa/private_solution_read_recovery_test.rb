require_relative '../../support/krowa'
require_relative '../../support/hidden_game_read_storage'
require_relative '../../../games/krowa_support/private_reveal'

# The owner has surrendered but other people are still playing. No new public
# game event needs to arrive just to finish reading this owner's own solution.
run = KrowaTestGame.new(variant: 'race', players: %w[Alice Bob Carol])
run.automatic
run.surrender('Alice')
assert(!run.replay.finished?, 'Fixture must retain two active players')
storage = HiddenGameReadStorage.new(run.program)
run.context.hidden_submissions = HiddenSubmissions::Vault.new(storage)
transport = Object.new
transport.define_singleton_method(:private_game_messages_pending?) { |_table, _session| false }
transport.define_singleton_method(:take_private_game_messages) { |_table, _session| [] }
transport.define_singleton_method(:send_private_game) { |**_| raise 'The host sent its own solution request over the network' }
now = 100.0
channel = GameRoomGames::KrowaPrivateReveal.new(run.game, transport, clock: -> { now })
storage.unreadable = true
begin
  channel.update(run.replay, 'Alice', run.context)
rescue HiddenSubmissions::StorageError
  # This is exactly the error swallowed/logged by KrowaClient#after_events.
end
assert(channel.word.nil?, 'A failed file read fabricated the solution')
assert(!channel.due?, 'A failed private solution read would retry every UI tick')
now += 5
assert(channel.due?, 'The surrendered host never retries its private solution without a new game event')
storage.unreadable = false
channel.update(run.replay, 'Alice', run.context)
assert(channel.word == 'kot', 'The private solution did not recover after the file lock')
assert(!channel.due?, 'A recovered private solution remains scheduled for polling')
assert(run.replay.state[:solution].nil?, 'Recovering a surrendered solution exposed it to active players')

puts 'PASS Krowa surrendered owner: bounded private-file retry without a new public game event or self-message'
