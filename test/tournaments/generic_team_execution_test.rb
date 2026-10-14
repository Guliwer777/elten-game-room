require_relative '../support/tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport
$stdout.sync = true
names = %w[Alpha Beta Gamma Delta]
game_family = ARGV.include?('--taboo') ? 'taboo' : 'domino'
game_id = ARGV.include?('--future') ? 'future_team_tiles' : game_family
registry = GameRoomGames::CATALOG
if ARGV.include?('--future')
  future = Class.new(GameRoomGames::Domino) do
    def id; 'future_team_tiles'; end
  end
  registry = GameRoomGames::Registry.new([future])
end
if ARGV.include?('--pl')
  GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
end
if ARGV.include?('--binary')
  require_relative '../support/tournament_native'
  require_relative '../../lib/tournaments/local_fixed_team_execution_screen'
  screen_path = File.expand_path('../../lib/tournaments/local_fixed_team_execution_screen.rb', __dir__)
  previous_verbose, $VERBOSE = $VERBOSE, nil
  begin
    Object.class_eval(File.binread(screen_path), screen_path)
  ensure
    $VERBOSE = previous_verbose
  end
end
if game_family == 'taboo'
  $generic_team_time = Time.now
  Time.singleton_class.prepend(Module.new do
    def now; $generic_team_time || super; end
  end)
end
existing = ARGV.first == '--finish-existing' && ARGV.fetch(1)
if ARGV.include?('--lost-reply')
  T::LocalFixedTeamExecutionStorage.prepend(Module.new do
    def write(document, receipt: nil)
      result = super
      if $generic_team_lost_reply && receipt && receipt['kind'] == 'move'
        $generic_team_lost_reply = false
        raise T::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'generic-team-lost-reply', receipt: receipt)
      end
      result
    end
  end)
end
scenario = lambda do |fixture|
  directory = File.join(fixture.directory, 'team-plans')
  if existing
    backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: fixture.tables, journal: fixture.journal,
      actor: 'Organizator', registry: fixture.registry, clock: -> { fixture.now })
    record = backend.readback(intent_id: 'generic-teams')
  else
  identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: fixture.tables.backend_identity)
  program = TournamentEntryContextTest::Program.new(directory)
  readiness = T::LocalReadinessSession.new
  readiness.choose_actor('Organizator')
  readiness.bind_backend(identity)
  owner = -> { fixture.owner }
  entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: owner, account_events: readiness.actor_events)
  authority = readiness.context(program: program, owner_reader: owner, entry: entry, lease: entry.capture, actor: 'Organizator', identity: identity)
  begin
    backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: fixture.tables, journal: fixture.journal,
      actor: 'Organizator', registry: fixture.registry, clock: -> { fixture.now }, context: authority)
    record = backend.accept(preview: backend.preview_pairs(publication_ref: fixture.reference,
      pairs: [%w[alpha beta], %w[gamma delta]], team_template: ARGV.include?('--creator-seat') ? [1, 0, 1, 0] : [0, 1, 0, 1], intent_id: 'generic-teams'))
    assert_equal(T::GameResult::CURRENT_RESULT_POLICY, record['evidence']['source']['result_policy'])
    if ARGV.include?('--knockout')
      candidate = record['preview']['source']['candidate']
      assert_equal('knockout', candidate['format'])
      assert_equal('direct_final', candidate['knockout']['origin'])
      assert_equal(false, candidate['rematch'])
    end
  ensure
    authority.close; entry.close; readiness.close; program.finalize
  end
  end
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
  path = File.join(directory, 'fixed-teams-v1/execution-ft2-v1/state.json')
  unless existing
  if ARGV.include?('--creator-seat')
    assert_equal('taboo', game_family)
    wrong_creator = people.min_by(&:downcase)
    assert(wrong_creator != people.first, 'The creator-policy scenario must differ from alphabetical ordering')
    before = File.exist?(path) ? File.binread(path) : nil
    with_declared_team_execution(fixture, record, wrong_creator) do |execution|
      rejected = execution.request_match
      assert_equal(:blocked, rejected[:state])
      assert_equal(:not_coordinator, rejected[:reason])
    end
    assert_equal(before, File.exist?(path) ? File.binread(path) : nil)
  end
  if ARGV.include?('--automatic')
    intent = record['preview']['intent_id']
    with_declared_team_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
    people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
    2.times { people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    invited = JSON.parse(File.binread(path))
    assert_equal(1, invited['native']['cores'].size)
    assert_equal(3, invited['native']['cores'].first['invitations'].size)
    assert_equal(1, invited['native']['cores'].first['participants'].size)
    assert_equal(people.first.downcase, invited['executions'].values.first['coordinator']) if ARGV.include?('--creator-seat')
    assert(invited['executions'].values.all? { |row| row['start'].nil? }, 'Explicit acceptance is required before Start')
    people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    started = JSON.parse(File.binread(path))
    assert_equal(1, started['native']['creates'].size)
    assert_equal(1, started['executions'].values.count { |row| row['start'] })
    assert_equal(4, started['native']['cores'].first['participants'].size)
    bytes = File.binread(path)
    people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    assert_equal(bytes, File.binread(path))
  else
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
  end
  end
  initial = JSON.parse(File.binread(path))['executions'].values.first
  offset = initial.fetch('moves', []).size
  finished = false
  surface_checked = false
  lost_reply_checked = false
  150.times do |iteration|
    number = offset + iteration
    view = nil
    with_declared_team_execution(fixture, record, people.first) { |e| view = e.local_game(action: :local_game_status)[:status] }
    if view['finished']
      finished = true
      with_declared_team_execution(fixture, record, people.first) do |e|
        result = e.local_game(action: :finalize_local_game, revision: view['revision'])
        assert_equal(:confirmed, result[:state], result.inspect)
        assert_equal(%w[team-001 team-002], result[:effect]['summary']['participants'])
        summary = result[:effect]['summary']
        assert(summary['draw'] || summary['winners'].size.between?(1, 2), 'The real game must identify complete source teams or a draw')
        if game_family == 'domino'
          if record['evidence']['source']['result_policy'] == T::GameResult::CURRENT_RESULT_POLICY
            assert_equal('lower', summary['score_order'])
            assert_equal(%w[team-001 team-002], summary['scores'].keys.sort)
            assert(summary['scores'].values.all? { |score| score.is_a?(Integer) && score >= 0 })
          else
            assert_equal(nil, summary['scores'])
          end
        else
          assert_equal([0, 2], summary['scores'].values.sort)
          assert_equal(1, summary['winners'].size)
        end
        e.progress['standings'].each do |row|
          assert_equal(summary['draw'] ? 1 : (summary['winners'].include?(row['team']) ? 2 : 0), row['points'])
          assert_equal(summary['scores'][row['team']], row['score_for']) if summary['score_order'] == 'lower'
        end
        if ARGV.include?('--knockout')
          progress = e.progress
          assert_equal(summary['draw'] ? 'tie_requires_resolution' : 'completed', progress['knockout_state'])
          assert_equal(summary['draw'] ? nil : summary['winners'].first, progress['champion'])
        end
      end
      break
    end
    acted = false
    selected = nil
    actors = [view['current_player'], *people].compact.uniq
    if game_family == 'taboo'
      state_document = JSON.parse(File.binread(path))
      execution_row = state_document['executions'].values.first
      model = fixture.registry.build(game_id)
      replay = nil
      T::LocalGameResult.with_core(state_document['native']['cores'].first, execution_row, owner: people.first) do |_tx, _transport, _table, repository, session|
        snapshot = repository.snapshot_for(session, force_events: true)
        replay = model.replay(snapshot.session, snapshot.events, repository)
      end
      state = replay.state
      # Read-only test oracle: choose ordinary game commands and advance the
      # isolated clock. No event, deadline, game state or result is manufactured.
      action = case state[:phase]
      when :awaiting_deal then actors = [people.first]; 'deal'
      when :ready then actors = [state[:current_player]]; 'start'
      when :preparing then $generic_team_time += 4; actors = [people.first]; 'begin'
      when :describing
        if state[:team].zero? && state[:review].empty?
          actors = [state[:current_player]]; 'correct'
        else
          $generic_team_time += 31; actors = [people.first]; 'timeout'
        end
      when :review then actors = [people.first]; 'approve'
      else raise "Unexpected actual Taboo phase #{state[:phase]}"
      end
      selected = {'action' => action, 'token' => model.token(state)}
    end
    actors.each do |actor|
      with_declared_team_execution(fixture, record, actor) do |e|
        own = e.local_game(action: :local_game_status)[:status]
        if game_family == 'domino'
          labelled = own['actions'].zip(own['action_labels']).select { |action, _label| action['action'] == 'play' }
          labelled.each do |action, label|
            assert(label.include?(GameRoomDominoTiles.label(action['tile'])), 'The legal move must name the actual own tile')
          end
          labelled.group_by { |action, _label| action['tile'] }.each_value do |choices|
            assert_equal(choices.size, choices.map(&:last).uniq.size, 'Different tile targets need distinct game-owned labels')
          end
        end
        choice = selected || own['actions'].first
        next unless choice
        if ARGV.include?('--surface') && game_family == 'taboo' && choice['action'] == 'start' && !surface_checked
          projection = e.local_game(action: :local_game_surface)[:effect]
          choice = native_team_surface_choice(projection, actor: actor, match_id: record['evidence']['plan']['matches'].first['match_id'])
          surface_checked = true
        end
        operation_id = "generic-team-#{number}"
        inject_lost_reply = ARGV.include?('--lost-reply') && !lost_reply_checked
        $generic_team_lost_reply = true if inject_lost_reply
        result = e.local_game(action: :local_game_move, operation_id: operation_id, revision: own['revision'], move_selection: choice)
        if inject_lost_reply
          assert_equal(:uncertain, result[:state], result.inspect)
          receipt = result[:receipt]
          bytes = File.binread(path)
          result = e.local_game(action: :local_move_status, operation_id: operation_id)
          assert_equal(:confirmed, result[:state])
          assert_equal(receipt, result[:effect])
          retry_result = e.local_game(action: :local_game_move, operation_id: operation_id, revision: own['revision'], move_selection: choice)
          assert_equal(:confirmed, retry_result[:state])
          assert_equal(receipt, retry_result[:effect])
          assert_equal(bytes, File.binread(path))
          lost_reply_checked = true
        end
        assert_equal(:confirmed, result[:state], result.inspect)
        acted = true
      end
      break if acted
    end
    assert(acted, 'No actor has a real game action')
    puts "PASS generic team #{game_id} move #{number + 1}" if number % 20 == 0
  end
  assert(finished, 'Generic team game did not finish within the bounded scenario')
  assert(surface_checked, 'The actual native team surface must submit a game move') if ARGV.include?('--surface')
  assert(lost_reply_checked, 'A durable generic move must survive a lost reply without replaying it') if ARGV.include?('--lost-reply')
  final = JSON.parse(File.binread(path))
  assert_equal({}, final['busy'])
  assert_equal(initial['start'], final['executions'].values.first['start'])
  assert_equal(initial.fetch('moves', []), final['executions'].values.first['moves'].take(offset))
  unless existing
    probe = File.expand_path('../support/tournament_generic_team_archive_probe.rb', __dir__)
    assert(system(RbConfig.ruby, probe, game_id, fixture.directory), 'Cold team archive verification failed')
  end
end
if existing
  fixture = TournamentLocalExecutionPlanSupport::Fixture.new(existing, game: 'domino', reopen: true)
  begin
    scenario.call(fixture)
  ensure
    fixture.close
  end
else
  options = game_family == 'domino' ? {'teams' => true, 'team_count' => '2', 'score_limit' => 1} : {'turns_each' => 1, 'turn_seconds' => 30}
  extra = ARGV.include?('--knockout') ? {group_advancement: T::GroupAdvancement::AUTOMATIC} : {}
  with_fixture(game: game_id, registry: registry, names: names, players_per_match: 4, rematch: false, game_options: options, **extra, &scenario)
end
puts "PASS generic team #{game_id}: accepted source-bound roster, real entry/Start/typed Runner moves, actual outcome, common 2/1/0 and busy release"
