require_relative '../support/native_live_sessions'

[:native, :discovery].product([:accepted, :snapshot]).each do |entry, boundary|
  broker = NativeLiveSessionsBroker.new
  owner = GameRoomTransport.new(ProgramDouble.new(broker.endpoint('Alice')))
  program = ProgramDouble.new(broker.endpoint('Bob'))
  guest = GameRoomTransport.new(program)
  $game_room_test_user = 'Alice'
  table = owner.create_room(name: 'Admission account boundary', game: 'uno',
    owner: 'Alice', game_options: '{}', private_table: true)
  owner.invite_user(table_id: table['__id'], user: 'Bob', metadata: {'invitation_id' => 91})
  $game_room_test_user = 'Bob'
  original_endpoint = program.live_sessions
  changed = 0
  change_account = lambda do
    changed += 1
    program.live_sessions = broker.endpoint('Other')
    $game_room_test_user = 'Other'
  end
  if boundary == :snapshot
    store = guest.instance_variable_get(:@live_store)
    snapshot = store.method(:room_snapshot)
    store.define_singleton_method(:room_snapshot) do |*args, **options|
      result = snapshot.call(*args, **options)
      change_account.call if changed.zero?
      result
    end
  end
  if entry == :native
    invitation = guest.pending_invitations.first.fetch('__native_invitation')
    if boundary == :accepted
      accept = invitation.method(:accept)
      invitation.define_singleton_method(:accept) do |**options|
        result = accept.call(**options)
        change_account.call
        result
      end
    end
    result = guest.accept_invitation(table_id: table['__id'], invitation_id: 91)
    assert(result == false, "Old native acceptance became success: #{boundary}")
  else
    discovered = guest.discover_rooms(include_private: true).first
    item = discovered.fetch('__discovered_session')
    if boundary == :accepted
      join = item.method(:join)
      item.define_singleton_method(:join) do |**options|
        result = join.call(**options)
        change_account.call
        result
      end
    end
    result = guest.establish_membership_status(table_id: table['__id'], owner: 'Alice',
      capacity: 8, user: 'Bob', table: discovered)
    assert(![:joined, :already_here].include?(result), "Old discovery acceptance became success: #{boundary}")
  end
  assert(changed == 1, "Account boundary was not reached: #{entry}/#{boundary}")
  assert(!guest.active_membership?(table['__id']), "Old membership attached after account change: #{entry}/#{boundary}")
  assert(broker.cores.fetch(table['__live_session_id']).participants.keys.sort == %w[alice bob],
    'Account guard must not remove the already accepted old membership or join the new account')
  $game_room_test_user = 'Bob'
  program.live_sessions = original_endpoint
  guest.start
  assert(guest.active_membership?(table['__id']), 'Original account cannot recover its accepted membership')
end

puts 'PASS native invitation/discovery admission stays on the original authenticated endpoint before and after snapshot'
