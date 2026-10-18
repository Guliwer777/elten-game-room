require_relative '../support/mille_private'

def retirement_fixture
  marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'retirement-boundary'},
    'schedule_id'=>'a' * 64, 'match_id'=>'b' * 64, 'leg'=>1}
  h = NativeRoomHarness.new(game: GameRoomGames::MilleBornes.new, users: %w[Alice Bob], tournament: marker)
  h.start
  view = h.view('Alice')
  old = view.create_pool(min: 1, max: 1, private_draws: true, message_id: 'old-retired-deck')
  replay = h.replay('Alice')
  context = GameRoomGames::ActionContext.new(table_owner: 'Alice')
  selection = h.game.automatic_action(replay, 'Alice', context: context)
  status, plan = h.game.action_for(selection, replay, 'Alice', context: context)
  assert(status == :ok && plan.events.first.pool_request['operation'] == 'create', 'expected native creation plan')
  # Retiring an otherwise unused old pool isolates the common native I/O
  # boundary; this test does not claim to complete Mille Bornes' scoring.
  plan.events.first.pool_request['retire'] = [old.id]
  view.singleton_class.prepend(Module.new do
    attr_accessor :fail_listing, :lose_delete_reply, :deleted_ids
    def pools
      if fail_listing
        self.fail_listing = false
        raise EltenAPI::LiveSessions::TimeoutError, 'pool listing failed before mutation'
      end
      super
    end
    def pool(id)
      candidate = super
      candidate.singleton_class.prepend(Module.new do
        def delete
          result = super
          view.deleted_ids ||= []
          view.deleted_ids << id
          if view.lose_delete_reply
            view.lose_delete_reply = false
            raise EltenAPI::LiveSessions::TimeoutError, 'retired pool reply lost'
          end
          result
        end
      end)
      candidate
    end
  end)
  store = h.transports['Alice'].instance_variable_get(:@live_store)
  room = store.instance_variable_get(:@rooms).fetch(h.table['__id'])
  [h, view, room, plan, old.id]
end

h, view, room, plan, old_id = retirement_fixture
before = h.core.entries.size
view.fail_listing = true
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Alice', plan.events) }
assert(room.pending_move.nil?, 'read-only pool listing created uncertain write')
assert(view.pools.map(&:id) == [old_id] && view.deleted_ids.nil?, 'failed listing retired a pool')
assert(h.core.entries.size == before, 'failed listing appended a game action')
h.write('Alice', plan.events)
assert(room.pending_move.nil? && view.deleted_ids == [old_id], 'fresh retry did not finish retirement exactly once')
assert(h.replay('Alice').state[:phase] == :private_wait, 'fresh retry did not publish new pool')

h, view, room, plan, old_id = retirement_fixture
before = h.core.entries.size
view.lose_delete_reply = true
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write('Alice', plan.events) }
pending = room.pending_move
assert(pending && pending[:uncertain], 'lost retirement ACK discarded uncertainty')
assert(view.pools.empty? && view.deleted_ids == [old_id], 'retirement did not occur exactly once')
assert(h.core.entries.size == before, 'pool announcement preceded successful preparation')
view.fail_listing = true
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.transports['Alice'].reconcile(h.table['__id']) }
assert(room.pending_move.equal?(pending) && pending[:uncertain], 'recovery read discarded earlier mutation identity')
h.transports['Alice'].reconcile(h.table['__id'])
assert(room.pending_move.nil? && view.pools.one? && view.deleted_ids == [old_id], 'retirement recovery duplicated or failed')
assert(h.core.entries.count { |entry| entry['message_id'] == pending.message_id } == 1, 'retirement recovery changed the operation UUID')
assert(h.replay('Alice').state[:phase] == :private_wait, 'retirement recovery did not publish new pool')
puts 'PASS independent pool retirement boundaries: failed listing has no write; lost deletion ACK survives later read failure and uses original UUID'
