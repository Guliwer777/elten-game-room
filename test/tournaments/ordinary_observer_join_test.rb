require 'tmpdir'
require_relative '../support/invitation_fresh_endpoint'
require_relative '../support/tournament_server_plan_table'

T = GameRoomTournaments
Dir.mktmpdir('ordinary-observers-', ENV.fetch('TMPDIR')) do |directory|
  broker = NativeLiveSessionsBroker.new
  gateway = DurableNoticeGateway.new
  game = EltenGameRoom::GAME_REGISTRY.build('tic_tac_toe')
  candidate = {
    'format'=>'round_robin', 'schedule_id'=>'a'*64, 'publication_digest'=>'b'*64,
    'roster_generation'=>'c'*64, 'game_id'=>game.id, 'game_options'=>game.default_options,
    'publication_ref'=>{'author'=>'alice', 'publication_key'=>'observer-fixture'},
    'roster'=>%w[alice bob carol],
    'matches'=>[{'match_id'=>'d'*64, 'leg'=>1, 'number'=>1, 'players'=>%w[alice bob]}]
  }
  key = JSON.generate(candidate.fetch('publication_ref'))
  docs = TournamentServerPlanTableSupport::Table.new(user: -> {'Alice'})
  apps = {}; services = {}
  %w[Alice Bob Carol Dave].each do |user|
    app = apps[user] = InvitationAppDriver.new(broker, user, gateway)
    services[user] = T::OrdinaryMatchService.new(program: app, registry: EltenGameRoom::GAME_REGISTRY,
      lobby: app.instance_variable_get(:@lobby), games: app.instance_variable_get(:@games),
      transport: app.transport, table: docs.for_user(user),
      journal: T::OperationJournal.new(directory: File.join(directory, user), owner: user.downcase, backend_identity: 'observer-test'),
      source: -> {{'candidate'=>candidate, 'tournament_id'=>1}}, user: -> {user})
    app.instance_variable_set(:@ordinary_tournament_services, {key=>services[user]})
  end
  $game_room_test_user = 'Alice'
  table = services['Alice'].open_match(match_id: 'd'*64, leg: 1)
  apps['Alice'].send(:deliver_table_invitation, table, 'Bob')
  $game_room_test_user = 'Bob'
  invitation = apps['Bob'].send(:load_pending_invitations).first.fetch(:invitation)
  assert(apps['Bob'].send(:accept_pending_invitation, invitation), 'Planned player could not accept')
  assert(!apps['Bob'].instance_variable_get(:@lobby).snapshot_for(table).observer?('Bob'), 'Planned player became an observer')

  # A registered tournament participant who is not in THIS fixture observes.
  $game_room_test_user = 'Carol'
  discovered = apps['Carol'].transport.discover_rooms.find {|row| row['__id'] == table['__id']}
  snapshot = LobbyRepository::TableSnapshot.new(table: discovered, members: %w[Alice Bob])
  assert(apps['Carol'].send(:join_table_snapshot, snapshot).entered?, 'Public table join failed')
  lobby = apps['Carol'].instance_variable_get(:@lobby)
  assert(lobby.snapshot_for(table).observer?('Carol'), 'Extra tournament participant entered as a player')
  count = broker.cores.fetch(table['__live_session_id']).entries.size
  docs.on_select = -> {raise 'Role selection reread tournament tables'}
  2.times {apps['Carol'].send(:apply_game_join_role, table)}
  assert(services['Carol'].observer_on_join?(table))
  assert(!services['Bob'].observer_on_join?(table))
  assert(broker.cores.fetch(table['__live_session_id']).entries.size == count, 'Repeated role setup wrote another event')
  assert_raises(T::OrdinaryMatchService::Blocked) {services['Carol'].observer_on_join?(table.merge('__live_session_id'=>'other'))}
  assert_raises(T::OrdinaryMatchService::Blocked) {services['Carol'].observer_on_join?(table.merge('tournament_match'=>table['tournament_match'].merge('leg'=>2)))}
  docs.on_select = nil

  # Leaving and coming back does not turn a planned player into a spectator.
  $game_room_test_user = 'Bob'
  apps['Bob'].send(:leave_current_table, table)
  assert(apps['Bob'].send(:join_table_snapshot, snapshot).entered?, 'Player could not return')
  assert(!apps['Bob'].instance_variable_get(:@lobby).snapshot_for(table).observer?('Bob'))
  $game_room_test_user = 'Alice'
  host_lobby = apps['Alice'].instance_variable_get(:@lobby)
  roster = host_lobby.snapshot_for(table, force: true).game_participants
  assert(roster.sort == %w[Alice Bob], "Wrong starting roster: #{roster}")
  params = services['Alice'].start_parameters(table, players: roster)
  session = apps['Alice'].instance_variable_get(:@games).start_session(
    table: table, game: game.id, options: JSON.generate(game.default_options), **params)
  assert(session['__players'] == %w[Alice Bob], 'Spectator changed canonical seats')

  # An outsider accepting an ordinary invitation after start also observes.
  apps['Alice'].send(:deliver_table_invitation, table, 'Dave')
  $game_room_test_user = 'Dave'
  invitation = apps['Dave'].send(:load_pending_invitations).first.fetch(:invitation)
  dave_lobby = apps['Dave'].instance_variable_get(:@lobby)
  role_writer = dave_lobby.method(:set_observer)
  dave_lobby.define_singleton_method(:set_observer) {|*| nil}
  assert(apps['Dave'].send(:accept_pending_invitation, invitation).nil?, 'Unconfirmed observer role reported a successful join')
  assert(!gateway.rows['Dave'].first.revoked, 'Role failure consumed the invitation')
  assert(apps['Dave'].errors.last.is_a?(GameRoomNetworkErrors::GamePaused))
  dave_lobby.define_singleton_method(:set_observer, role_writer)
  apps['Dave'].send(:accept_pending_invitation, invitation)
  assert(gateway.rows['Dave'].first.revoked, 'Retry did not complete the invitation')
  state = apps['Dave'].instance_variable_get(:@lobby).snapshot_for(table, force: true)
  assert(state.observer?('Dave') && state.game_participants.sort == %w[Alice Bob], 'Active match acquired an extra player')
  repo = apps['Dave'].instance_variable_get(:@games)
  recorded = repo.snapshot_for(session)
  replay = game.replay(recorded.session, recorded.events, repo)
  assert(game.legal_actions(replay, 'Dave').empty?, 'Spectator acquired game actions')

  # Unknown/stale bindings fail closed instead of choosing an arbitrary role.
  apps['Dave'].instance_variable_set(:@ordinary_tournament_services, {})
  assert_raises(GameRoomNetworkErrors::GamePaused) {apps['Dave'].send(:apply_game_join_role, table)}
ensure
  docs.on_select = nil if docs
  services&.each_value(&:close)
end
puts 'PASS ordinary tournament observers: public join, invitation, registered outsider, planned-player return, active match, canonical seats, no duplicate role writes or tournament reads, stale binding rejection'
