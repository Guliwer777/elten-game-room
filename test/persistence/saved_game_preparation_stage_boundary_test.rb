require_relative '../support/saved_games_ui'

# Independent review of explicit continuation preparation: production app,
# native lobby and archive, with only managed-task delivery boundaries injected.
class SavedPreparationStageDriver < SaveAppDriver
  attr_accessor :discard_preparation, :before_invitation
  attr_reader :preparation_count, :activation_count

  def initialize(broker)
    super
    @preparation_count = @activation_count = 0
  end

  def run_network_task(title, **options, &block)
    @preparation_count += 1 if title == 'Preparing saved game'
    if title == 'Sending invitation' && @before_invitation
      @before_invitation.call
    end
    result = super(title, **options, &block)
    if title == 'Preparing saved game' && @discard_preparation == @preparation_count
      @discard_preparation = nil
      return nil
    end
    result
  end

  def activate_table_transport(table)
    @activation_count += 1
    super
  end
end

def preparation_stage_fixture(private_table: false)
  $game_room_test_user = 'Alice'
  InvitationRepository::SENT_LOCK.synchronize { InvitationRepository::SENT.clear }
  broker = NativeLiveSessionsBroker.new
  app = SavedPreparationStageDriver.new(broker)
  game = GameRoomGames::TicTacToe.new
  original = app.lobby.create_table(name: 'Continuation stages', game: game.id,
    owner: 'Alice', private_table: private_table).table
  app.lobby.set_observer(original, 'Alice', true)
  guests = %w[Bob Carol].map do |user|
    transport = GameRoomTransport.new(ProgramDouble.new(broker.endpoint(user)))
    join_preparation_stage_guest(app, transport, original, user)
    transport
  end
  session = app.games.start_session(table: original, game: game.id, players: %w[Bob Carol],
    options: JSON.generate(game.default_options))
  saved = app.send(:saved_games).put(game: game, table: original,
    snapshot: app.games.snapshot_for(session), repository: app.games)
  app.lobby.close_table(original)
  [app, broker, saved, guests]
end

def join_preparation_stage_guest(app, transport, table, user)
  app.transport.invite_user(table_id: table['__id'], user: user, metadata: {}) if table['private']
  discovered = transport.discover_rooms(include_private: true).find { |row| row['__id'] == table['__id'] }
  assert(transport.establish_membership(table_id: table['__id'], owner: table['owner'],
    capacity: 8, user: user, table: discovered), 'Fixture guest could not join the native room')
end

def stage_state(broker, table)
  core = broker.cores.fetch(table['__live_session_id'])
  Marshal.load(Marshal.dump([core.entries, core.metadata]))
end

# This injection is independent of how many managed preparation stages exist.
# It is also the control against the old complete method: the room survives a
# failed own-role request, and the explicit retry must actually finish setup.
app, broker, saved = preparation_stage_fixture
write_role = app.transport.method(:set_observer)
fail_once = true
app.transport.define_singleton_method(:set_observer) do |*arguments, **options|
  if fail_once
    fail_once = false
    raise EltenAPI::LiveSessions::TimeoutError, 'Independent own-role request unavailable'
  end
  write_role.call(*arguments, **options)
end
assert(app.send(:create_saved_game_table, saved).nil?, 'Own-role failure was reported as completed')
retained = app.lobby.current_table_for('Alice')
assert(retained && !app.lobby.snapshot_for(retained).observer?('Alice'), 'Own-role failure did not retain its incomplete room')
recovered = app.send(:create_saved_game_table, saved)
assert(recovered && app.lobby.snapshot_for(recovered).observer?('Alice'),
  'Explicit retry left the saved-game owner occupying an original playing seat')
assert(app.notices.grep(Array).map(&:first) == %w[Bob Carol], 'Recovered role did not finish its invitations')
app.lobby.close_table(recovered)

[false, true].each do |private_table|
  [1, 2].each do |stage|
    app, broker, saved, guests = preparation_stage_fixture(private_table: private_table)
    app.discard_preparation = stage
    assert(app.send(:create_saved_game_table, saved).nil?, 'Discarded task result reported completed preparation')
    retained = app.lobby.current_table_for('Alice')
    assert(retained && app.notices.grep(Array).empty?, 'Preparation result loss discarded the room or sent invitations')
    assert(app.send(:saved_games).fetch(saved['id']) == saved, 'Preparation consumed the stored archive')
    first_role = app.lobby.snapshot_for(retained, force: true).observer?('Alice')
    assert(first_role == (stage == 2), 'Fault was not injected after the requested completed stage')
    before = stage_state(broker, retained)
    recovered = app.send(:create_saved_game_table, saved)
    assert(recovered && recovered['__id'] == retained['__id'], 'Explicit retry created a second continuation')
    assert(app.lobby.snapshot_for(recovered, force: true).observer?('Alice'),
      'Lost creation reply caused explicit retry to skip the archive owner role')
    assert(app.activation_count == 1, 'Already confirmed activation was repeated')
    assert(app.notices.grep(Array).map(&:first) == %w[Bob Carol], 'Original humans were not invited once')
    assert(stage_state(broker, recovered) == before, 'Completed role stage was written again') if stage == 2
    assert(app.instance_variable_get(:@saved_game_table_preparation).nil?, 'Completed preparation retained a retry intention')
    %w[Bob Carol].zip(guests).each { |user, transport| join_preparation_stage_guest(app, transport, recovered, user) }
    started = app.send(:resume_saved_game_at_table, recovered, app.room_state(recovered))
    assert(started && app.games.players_for(started) == %w[Bob Carol], 'Recovered continuation changed original playing seats')
    assert(app.send(:saved_games).fetch(saved['id']).nil?, 'Confirmed restore did not consume exactly its archive')
    app.lobby.close_table(recovered)
  end
end

# A successful first invitation does not authorize the remaining invitations
# after ownership, membership or account changes during the next managed wait.
[:owner, :membership, :account, :started].each do |change|
  app, broker, saved, guests = preparation_stage_fixture
  calls = 0
  retained = nil
  app.before_invitation = lambda do
    calls += 1
    next unless calls == 2
    retained = app.lobby.current_table_for('Alice')
    case change
    when :owner
      join_preparation_stage_guest(app, guests.first, retained, 'Bob')
      app.transport.transfer_room_owner(retained, 'Bob')
    when :membership
      app.lobby.close_table(retained)
      app.lobby.create_table(name: saved['table_name'], game: saved['game'], owner: 'Alice',
        game_options: saved['options'], resume_save_id: saved['id'])
    when :account
      $game_room_test_user = 'Carol'
    when :started
      app.lobby.set_game_active(retained, true)
    end
  end
  assert(app.send(:create_saved_game_table, saved).nil?, 'Changed preparation identity was reported as completed')
  assert(app.notices.grep(Array).map(&:first) == ['Bob'], "Remaining invitation crossed #{change} boundary")
  assert(app.instance_variable_get(:@saved_game_table_preparation).nil?, 'Invalidated preparation retained permission to retry')
  $game_room_test_user = 'Alice'
  assert(app.send(:saved_games).fetch(saved['id']) == saved, 'Invalidated preparation consumed the archive')
  current = app.lobby.current_table_for('Alice')
  baseline = stage_state(broker, current)
  app.send(:create_saved_game_table, saved)
  assert(stage_state(broker, current) == baseline && app.notices.grep(Array).map(&:first) == ['Bob'],
    'A later explicit call silently resurrected invalidated setup')
  app.transport.deactivate_table(table_id: current['__id'])
end

puts 'PASS independent saved preparation: lost creation/role result, original-seat restore and invitation identity boundaries'
