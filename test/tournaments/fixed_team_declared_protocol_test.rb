require_relative '../support/tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport
$stdout.sync = true
future = Class.new(GameRoomGames::Spades) do
  def id; 'future_team_cards'; end
end
registry = GameRoomGames::Registry.new([future])
with_fixture(game: 'future_team_cards', registry: registry, names: %w[Alpha Beta Gamma Delta],
  players_per_match: 4, rematch: false, game_options: {'team_size' => 2, 'score_limit' => 1}) do |fixture|
  directory = File.join(fixture.directory, 'team-plans')
  identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: fixture.tables.backend_identity)
  program = TournamentEntryContextTest::Program.new(directory)
  session = T::LocalReadinessSession.new
  session.choose_actor('Organizator')
  session.bind_backend(identity)
  owner = -> { fixture.owner }
  entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: owner,
    account_events: session.actor_events)
  authority = session.context(program: program, owner_reader: owner, entry: entry, lease: entry.capture,
    actor: 'Organizator', identity: identity)
  begin
    backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: fixture.tables,
      journal: fixture.journal, actor: 'Organizator', registry: registry, clock: -> { fixture.now }, context: authority)
    shown = backend.preview_pairs(publication_ref: fixture.reference,
      pairs: [%w[alpha beta], %w[gamma delta]], team_template: [0, 1, 0, 1], intent_id: 'future-team-plan')
    record = backend.accept(preview: shown)
    assert_equal('future_team_cards', record['evidence']['source']['game_id'])
    match = record['evidence']['plan']['matches'].first
    payload = T::FixedTeamNativePayload.from_execution_plan(evidence: record['evidence'], expected_source: record['expected_source'],
      match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'], registry: registry)
    assert_equal(4, payload.to_h['players'].size)
    assert_equal([0, 1, 0, 1], payload.to_h['options']['team_seats'])
    assert_equal(record, backend.readback(intent_id: 'future-team-plan'))
    cold = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: fixture.tables,
      journal: fixture.journal, actor: 'Organizator', registry: registry, clock: -> { fixture.now })
    assert_equal(record, cold.readback(intent_id: 'future-team-plan'))
  ensure
    authority.close
    entry.close
    session.close
    program.finalize
  end
  if ARGV.include?('--execute')
    people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
    people.each { |actor| with_declared_team_execution(fixture, record, actor) { |e| assert_equal(:confirmed, e.declare(availability: 'ready', expected_revision: 0)[:state]) } }
    binding = nil
    with_declared_team_execution(fixture, record, people.first) do |e|
      assert_equal(:bound, e.request_match[:state])
      binding = T::CoordinationContract.digest(e.admission(action: :admission_status)[:status]['binding'])
    end
    people.each do |actor|
      with_declared_team_execution(fixture, record, actor) do |e|
        consent = e.admission(action: :consent, binding_digest: binding)[:effect]
        assert_equal(:confirmed, e.admission(action: :enter, consent_id: consent['id'])[:state])
      end
    end
    with_declared_team_execution(fixture, record, people.first) { |e| assert_equal(:confirmed, e.local_game(action: :start_local_game, binding_digest: binding)[:state]) }
    finished = false
    60.times do |number|
      view = nil
      with_declared_team_execution(fixture, record, people.first) { |e| view = e.local_game(action: :local_game_status)[:status] }
      if view['finished']
        finished = true
        with_declared_team_execution(fixture, record, people.first) do |e|
          result = e.local_game(action: :finalize_local_game, revision: view['revision'])
          assert_equal(:confirmed, result[:state], result.inspect)
          assert_equal([2, 0], e.progress['standings'].map { |row| row['points'] }.sort.reverse)
        end
        break
      end
      actor = view['current_player'] || view['players'].first
      with_declared_team_execution(fixture, record, actor) do |e|
        own = e.local_game(action: :local_game_status)[:status]
        choice = own['actions'].find { |action| action['action'] == 'bid_3' } || own['actions'].first
        assert(choice, 'Missing real game-owned card action')
        result = e.local_game(action: :local_game_move, operation_id: "future-team-#{number}", revision: own['revision'], move_selection: choice)
        assert_equal(:confirmed, result[:state], result.inspect)
      end
      puts "PASS future team game move #{number + 1}" if number % 20 == 0
    end
    assert(finished, 'Future compatible card game did not finish within one bounded round')
    path = File.join(directory, 'fixed-teams-v1/execution-ft2-v1/state.json')
    assert_equal({}, JSON.parse(File.binread(path))['busy'])
    bytes = File.binread(path)
    probe = File.expand_path('../support/tournament_declared_team_finish_probe.rb', __dir__)
    output = IO.popen([RbConfig.ruby, probe, fixture.directory], err: [:child, :out], &:read)
    assert($?.success?, output)
    assert_equal(bytes, File.binread(path))
    puts 'PASS actual future compatible team game: full Runner round, real winning team, common 2/0 and cold result'
  end
end
assert_equal('game-owned-turn-actions-v1', GameRoomGames::CATALOG.build('domino').tournament_fixed_team_protocol)
assert_equal('game-owned-turn-actions-v1', GameRoomGames::CATALOG.build('taboo').tournament_fixed_team_protocol)
assert_equal('game-owned-realtime-actions-v1', GameRoomGames::CATALOG.build('axel_pong').tournament_fixed_team_protocol)
unconnected = Class.new(GameRoomGames::AxelPong) do
  def tournament_realtime_point_action; nil; end
end.new
assert_equal(nil, unconnected.tournament_fixed_team_protocol)
assert_equal(false, unconnected.tournament_fixed_team_actions?)
puts 'PASS declared team protocol: future compatible game accepts source-bound team plan/native roster without an ID allowlist; unconnected game protocols stay closed'
