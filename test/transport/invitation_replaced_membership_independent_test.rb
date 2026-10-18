require_relative '../support/native_live_sessions'

# A late result for Bob must not overwrite or clean up the membership that a
# replacement runtime has already established. This uses real broker views and
# the normal store recovery entry point, not a fabricated @sessions assignment.
[:accepted, :snapshot].product(['Other', 'Bob']).each do |boundary, next_user|
  broker = NativeLiveSessionsBroker.new
  owner = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Alice')))
  program = ProgramDouble.new(broker.endpoint('Bob'))
  guest = GameRoomTransport.new(program)
  $game_room_test_user = 'Alice'
  table = owner.create_room(name: 'Superseded acceptance', game: 'uno', owner: 'Alice', game_options: '{}')
  owner.invite_user(table_id: table['__id'], user: 'Bob', metadata: {'invitation_id' => 91})
  core = broker.cores.fetch(table['__live_session_id'])
  $game_room_test_user = 'Bob'
  invitation = guest.pending_invitations.first.fetch('__native_invitation')
  store = guest.instance_variable_get(:@live_store)
  replacements = 0
  replacement = nil
  replace = lambda do
    replacements += 1
    endpoint = broker.endpoint(next_user, fresh: true)
    program.live_sessions = endpoint
    $game_room_test_user = next_user
    replacement = endpoint.add_view(core)
    guest.start
    assert(store.instance_variable_get(:@sessions)[table['__id']].equal?(replacement), 'New endpoint did not recover its native view')
  end

  if boundary == :accepted
    original = invitation.method(:accept)
    invitation.define_singleton_method(:accept) do |**options|
      old_session = original.call(**options)
      replace.call
      old_session
    end
  else
    original = store.method(:room_snapshot)
    store.define_singleton_method(:room_snapshot) do |*arguments, **options|
      old_snapshot = original.call(*arguments, **options)
      replace.call if replacements.zero?
      old_snapshot
    end
  end

  result = guest.accept_invitation(table_id: table['__id'], invitation_id: 91)
  label = [boundary, next_user].inspect
  assert(result == false, "Superseded operation became successful: #{label}")
  assert(replacements == 1, "Injection did not run exactly once: #{label}")
  assert(guest.active_membership?(table['__id']), "Stale cleanup removed the new membership: #{label}")
  assert(store.instance_variable_get(:@sessions)[table['__id']].equal?(replacement), "Stale callback overwrote the new native session: #{label}")
  assert(!replacement.closed? && core.views.none?(&:closed?), "Stale completion left/closed a remotely accepted membership: #{label}")
  assert(core.participants.keys.sort == (%w[alice bob] + [next_user.downcase]).uniq.sort, "Remote membership was changed by stale cleanup: #{label}")

  # Native callbacks of the old Bob view remain harmless after it is superseded.
  old_views = core.views.select { |view| view.user == 'Bob' && !view.equal?(replacement) }
  old_views.each { |view| view.instance_variable_get(:@closed_callbacks).each(&:call) }
  assert(store.instance_variable_get(:@sessions)[table['__id']].equal?(replacement), "Old closed callback removed current session: #{label}")
end

puts 'PASS independent invitation late completion: replacement memberships and same-account fresh endpoints survive old accept/snapshot/closed callbacks'
