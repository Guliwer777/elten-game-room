require_relative '../support/mille_private'

def private_preflight_harness
  marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'read-preflight'},
    'schedule_id'=>'a' * 64, 'match_id'=>'b' * 64, 'leg'=>1}
  h = NativeRoomHarness.new(game: GameRoomGames::MilleBornes.new, users: %w[Alice Bob], tournament: marker)
  h.start
  runners = h.users.to_h { |user| [user, runner_for(h, user)] }
  step(h, runners['Alice'], 'Alice')
  replay = h.replay('Bob')
  assert(replay.state[:phase] == :private_wait, 'fixture must stop before checking the pool')
  selection = h.game.automatic_action(replay, 'Bob')
  status, plan = h.game.action_for(selection, replay, 'Bob')
  assert(status == :ok && plan.events.first.pool_request['operation'] == 'check', 'fixture must use native pool verification')
  view = h.view('Bob')
  view.singleton_class.prepend(Module.new do
    attr_accessor :fail_pool_state_once
    def pool_state(id)
      if fail_pool_state_once
        self.fail_pool_state_once = false
        raise EltenAPI::LiveSessions::TimeoutError, 'pool verification read timed out'
      end
      super
    end
  end)
  [h, runners, plan]
end

h, runners, plan = private_preflight_harness
view = h.view('Bob')
view.fail_pool_state_once = true
before_entries, before_pushes = h.core.entries.size, view.calls[:push]
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Bob', plan.events) }
assert(h.core.entries.size == before_entries && view.calls[:push] == before_pushes, 'a read failure attempted a mutation')
assert(!h.transports['Bob'].pending_move_error(h.table['__id']), 'read-only preflight left a phantom uncertain move')
h.write('Bob', plan.events)
12.times { MillePrivateTest.tick(h, runners) }
MillePrivateTest.assert_private(h)
assert(h.replay('Alice').state[:phase] == :awaiting_draw, 'successful retry did not finish dealing')
runners.each_value(&:close)

# In contrast, a write that was actually attempted keeps its original UUID
# even if a subsequent verification read fails before its recovery push.
h, runners, plan = private_preflight_harness
view = h.view('Bob')
view.fail_next_push = :before
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Bob', plan.events) }
store = h.transports['Bob'].instance_variable_get(:@live_store)
room = store.instance_variable_get(:@rooms).fetch(h.table['__id'])
pending = room.pending_move
assert(pending && pending[:uncertain], 'an attempted push lost its uncertain identity')
room.verified_pools.clear
view.fail_pool_state_once = true
pushes = view.calls[:push]
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.transports['Bob'].reconcile(h.table['__id']) }
assert(view.calls[:push] == pushes, 'failing recovery read sent another push')
assert(room.pending_move.equal?(pending) && pending[:uncertain], 'a later read failure cleared the uncertain operation')
h.transports['Bob'].reconcile(h.table['__id'])
assert(room.pending_move.nil?, 'successful recovery did not clear the pending slot')
assert(h.core.entries.count { |entry| entry['message_id'] == pending.message_id } == 1, 'recovery duplicated or changed the operation')
runners.each_value(&:close)

# Pool creation is already a server mutation, even when its following stack
# announcement has not been sent. Retain that uncertain identity and reuse
# the native idempotent create instead of allocating a different deck.
marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'create-preflight'},
  'schedule_id'=>'a' * 64, 'match_id'=>'b' * 64, 'leg'=>1}
h = NativeRoomHarness.new(game: GameRoomGames::MilleBornes.new, users: %w[Alice Bob], tournament: marker)
h.start
view = h.view('Alice')
view.singleton_class.prepend(Module.new do
  def create_pool(**options)
    pool = super
    unless @lost_create_reply
      @lost_create_reply = true
      raise EltenAPI::LiveSessions::TimeoutError, 'created pool reply was lost'
    end
    pool
  end
end)
replay = h.replay('Alice')
context = GameRoomGames::ActionContext.new(table_owner: 'Alice')
selection = h.game.automatic_action(replay, 'Alice', context: context)
status, plan = h.game.action_for(selection, replay, 'Alice', context: context)
assert(status == :ok && plan.events.first.pool_request['operation'] == 'create', 'fixture did not request creating a deck')
before_pushes = view.calls[:push]
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Alice', plan.events) }
store = h.transports['Alice'].instance_variable_get(:@live_store)
room = store.instance_variable_get(:@rooms).fetch(h.table['__id'])
pending = room.pending_move
assert(pending && pending[:uncertain] && view.calls[:push] == before_pushes, 'created deck uncertainty was lost before the announcement')
original_pool = view.pools.map(&:id)
h.transports['Alice'].reconcile(h.table['__id'])
assert(view.pools.map(&:id) == original_pool && original_pool.one?, 'recovery allocated another deck')
assert(room.pending_move.nil? && h.replay('Alice').state[:phase] == :private_wait, 'created deck was not recovered')
puts 'PASS private pool preflight: no phantom write after failed read, original uncertain UUID retained on recovery'
