require_relative '../../support/duck_game_adapter'

include DuckGameAdapterTest

class DuckCleanupStorage < HiddenSubmissions::MemoryStorage
  attr_accessor :blocked, :forbid_read
  attr_reader :reads
  def initialize; super; @reads = 0; end
  def read
    raise 'Cleanup touched storage outside an executor boundary' if @forbid_read
    @reads += 1
    super
  end
  def update(&block)
    raise HiddenSubmissions::StorageError, 'Deliberately unavailable local cleanup' if @blocked
    super
  end
end

def setup_cleanup_round
  fixture = DuckGameAdapterTest::Harness.new
  storage = fixture.players.to_h { |actor| [actor, DuckCleanupStorage.new] }
  storage.each { |actor, value| fixture.vaults[actor] = HiddenSubmissions::Vault.new(value) }
  fixture.open_round
  fixture.begin_round
  [fixture, storage]
end

def submit_cleanup_traces(fixture)
  id = fixture.replay.state[:round][:challenge][:id]
  fixture.private_traces.each do |seat, trace|
    fixture.accept({'action' => 'submit_trace', 'challenge' => id, 'trace' => trace},
      actor: fixture.players[seat])
  end
  assert_equal(:revealing, fixture.replay.state[:round][:private][:phase])
  id
end

def finish_cleanup_reveal(fixture, actor)
  id = fixture.replay.state[:round][:challenge][:id]
  40.times do
    current = fixture.replay
    break if current.state[:last_resolution]&.[](:id) == id ||
      current.state.dig(:round, :private, :reveals)&.key?(fixture.players.index(actor))
    selection = fixture.game.automatic_action(current, actor, context: fixture.context(actor))
    raise 'No pending reveal' unless selection && selection['action'] == 'reveal'
    fixture.accept(selection, actor: actor)
  end
end

# Preparing a local attempt is not proof that the server accepted its commit.
fixture, storage = setup_cleanup_round
id = fixture.replay.state[:round][:challenge][:id]
trace = fixture.private_traces.fetch(0)
status, unacknowledged = fixture.plan({'action' => 'submit_trace', 'challenge' => id, 'trace' => trace},
  actor: 'Alice')
assert_equal(:ok, status)
assert_equal(2, storage['Alice'].read['entries'].size)
pending = Marshal.dump(storage['Alice'].read)
fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal(pending, Marshal.dump(storage['Alice'].read), 'Uncertain commit was discarded')
fixture.append(unacknowledged, actor: 'Alice')
fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal(pending, Marshal.dump(storage['Alice'].read), 'Accepted commit alone caused cleanup')

# Planning a reveal also does not confirm it. The accepted payload, not a UI
# state or page being queued, is the boundary for deleting the durable copy.
fixture.accept({'action' => 'submit_trace', 'challenge' => id, 'trace' => fixture.private_traces.fetch(1)},
  actor: 'Bob')
assert_equal(:revealing, fixture.replay.state[:round][:private][:phase])
selection = fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal('reveal', selection['action'])
assert_equal(pending, Marshal.dump(storage['Alice'].read))
finish_cleanup_reveal(fixture, 'Alice')
assert(fixture.replay.state.dig(:round, :private, :reveals).key?(0))
before_state = Marshal.dump(fixture.replay.state)
fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal({}, storage['Alice'].read['entries'], 'Confirmed own reveal retained its private stream')
assert_equal(2, storage['Bob'].read['entries'].size, 'Another account was cleaned')
assert_equal(before_state, Marshal.dump(fixture.replay.state), 'Cleanup modified the accepted replay')
finish_cleanup_reveal(fixture, 'Bob')
assert_equal(id, fixture.replay.state[:last_resolution][:id])
fixture.game.automatic_action(fixture.replay, 'Bob', context: fixture.context('Bob'))
assert_equal({}, storage['Bob'].read['entries'], 'Final revealer lost its confirmed cleanup boundary')

# A real accepted cancellation is enough even if the commit was only prepared.
fixture, storage = setup_cleanup_round
id = fixture.replay.state[:round][:challenge][:id]
fixture.plan({'action' => 'submit_trace', 'challenge' => id, 'trace' => fixture.private_traces.fetch(0)},
  actor: 'Alice')
fixture.accept({'action' => 'cancel', 'challenge' => id, 'reason' => 'technical'}, actor: 'Bob')
assert_equal(:technical, fixture.replay.state[:last_resolution][:cancelled])
before = Marshal.dump(storage['Alice'].read)
fresh = GameRoomGames::DuckRacing.new(resources: fixture.resources)
storage['Alice'].blocked = true
fresh.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal(before, Marshal.dump(storage['Alice'].read), 'Failed recovery cleanup destroyed the envelope')
wrong_context = fixture.context('Alice')
wrong_context.session_id += 1
fixture.game.duck_cleanup_private(fixture.replay, 'Alice', wrong_context)
assert_equal(before, Marshal.dump(storage['Alice'].read), 'Different native session authorized cleanup')
fixture.game.automatic_action(fixture.replay, 'Bob', context: fixture.context('Bob'))
assert_equal(before, Marshal.dump(storage['Alice'].read), 'Different account authorized cleanup')
fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal(before, Marshal.dump(storage['Alice'].read), 'Failed cleanup destroyed the retry reference')
storage['Alice'].blocked = false
fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal({}, storage['Alice'].read['entries'], 'Ordinary later worker call did not retry cleanup')
previous_reads = storage['Alice'].reads
fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal(previous_reads, storage['Alice'].reads, 'Successful cleanup kept reading storage')

# Restarting the executor while revealing uses accepted scope/commit evidence.
fixture, storage = setup_cleanup_round
id = submit_cleanup_traces(fixture)
fresh = GameRoomGames::DuckRacing.new(resources: fixture.resources)
fixture.instance_variable_set(:@game, fresh)
fixture.players.each { |actor| finish_cleanup_reveal(fixture, actor) }
fixture.players.each do |actor|
  fixture.game.automatic_action(fixture.replay, actor, context: fixture.context(actor))
  assert_equal({}, storage[actor].read['entries'])
end

# Disk work must not leak into replay or the shared scheduling predicate.
fixture, storage = setup_cleanup_round
submit_cleanup_traces(fixture)
storage['Alice'].forbid_read = true
current = fixture.replay
assert(fixture.game.automatic_action_due?(current, 'Alice', context: fixture.context('Alice')))
storage['Alice'].forbid_read = false
assert_equal(2, storage['Alice'].read['entries'].size)

# An old cleanup reference must never delete a different current envelope,
# even if a deliberately inconsistent local store contains one.
fixture, storage = setup_cleanup_round
id = fixture.replay.state[:round][:challenge][:id]
fixture.plan({'action' => 'submit_trace', 'challenge' => id, 'trace' => fixture.private_traces.fetch(0)},
  actor: 'Alice')
fixture.accept({'action' => 'cancel', 'challenge' => id, 'reason' => 'technical'}, actor: 'Bob')
vault = fixture.vault('Alice')
original = vault.reveal(session_id: fixture.session['__id'], round_id: "duck:#{id}", user: 'Alice')
vault.prepare(session_id: fixture.session['__id'], round_id: "duck:#{id}", user: 'Alice',
  payload: {'different' => 'attempt'}, nonce: 'f' * 64)
before = Marshal.dump(storage['Alice'].read)
fixture.game.automatic_action(fixture.replay, 'Alice', context: fixture.context('Alice'))
assert_equal(before, Marshal.dump(storage['Alice'].read))
assert(vault.reveal(session_id: fixture.session['__id'],
  round_id: "duck-wire-v2:#{original.commitment}", user: 'Alice'))

# The worker's refresh hook also cleans a final match replay: it must not need
# another player's turn, UI input or the original game instance.
fixture, storage = setup_cleanup_round
id = fixture.replay.state[:round][:challenge][:id]
fixture.plan({'action' => 'submit_trace', 'challenge' => id, 'trace' => fixture.private_traces.fetch(0)},
  actor: 'Alice')
fixture.accept({'action' => 'cancel', 'challenge' => id, 'reason' => 'technical'}, actor: 'Bob')
completed = fixture.replay.dup
completed.winner = 'Alice'
before = Marshal.dump(storage['Alice'].read)
assert_equal(nil, fixture.game.automatic_action(completed, 'Alice', context: fixture.context('Alice')))
assert_equal(before, Marshal.dump(storage['Alice'].read))
fresh = GameRoomGames::DuckRacing.new(resources: fixture.resources)
fresh.cleanup_session_answers(completed, session_id: fixture.session['__id'], actors: ['Alice'],
  hidden_submissions: fixture.vault('Alice'))
assert_equal({}, storage['Alice'].read['entries'])

# A later challenge/result does not erase the accepted cleanup proof.
fixture, storage = setup_cleanup_round
submit_cleanup_traces(fixture)
fixture.players.each { |actor| finish_cleanup_reveal(fixture, actor) }
replay = fixture.replay
replay.state[:last_resolution] = {id: 999, kind: 'dice_duel'}
fresh = GameRoomGames::DuckRacing.new(resources: fixture.resources)
fixture.players.each do |actor|
  fresh.cleanup_session_answers(replay, session_id: fixture.session['__id'], actors: [actor],
    hidden_submissions: fixture.vault(actor))
  assert_equal({}, storage[actor].read['entries'], 'Recreated worker lost the earlier confirmed scope')
end

puts 'PASS Duck cleanup integration: accepted own reveal/cancel only, final revealer, uncertain writes preserved, recovery, isolated account/session, retry, no replay/UI polling'
