require_relative 'tournament_individual_execution'
require_relative '../../lib/tournaments/local_fixed_team_plan_backend'
require_relative '../../lib/tournaments/local_fixed_team_execution'
module TournamentDeclaredTeamExecutionSupport
  include TournamentIndividualExecutionSupport
  def with_declared_team_dispatch(fixture, record, actor)
    require_relative '../../lib/tournaments/local_fixed_team_dispatcher'
    index = record['evidence']['plan']['matches'].index { |match| match['players'].any? { |person| person['account'] == actor.downcase } } || 0
    with_declared_team_execution(fixture, record, actor, index) do |execution|
      dispatcher = T::LocalFixedTeamDispatcher.new(plan_backend: execution.instance_variable_get(:@backend),
        plan_directory: File.join(fixture.directory, 'team-plans'), source_identity: fixture.tables.backend_identity,
        context: execution.instance_variable_get(:@context), registry: fixture.registry,
        clock: execution.instance_variable_get(:@clock), policy_ref: 'generic-team-dispatch-test', expires_at: nil)
      yield dispatcher
    end
  end

  def native_team_surface_choice(projection, actor:, match_id:)
    require_relative 'tournament_native'
    require_relative '../../lib/tournaments/local_fixed_team_execution_screen'
    require File.join(EltenTestHost.root, 'src/ui/controls/grid_box')
    Object.const_set(:GridBox, EltenAPI::Controls.const_get(:GridBox)) unless defined?(GridBox)
    require_relative '../../lib/game_surfaces'
    previous_runtime = TournamentEntryContextTest::Program.app_runtime
    program = TournamentEntryContextTest::Program.new
    own_runtime = program.class.app_runtime
    session = T::LocalReadinessSession.new
    session.choose_actor(actor)
    context = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
      owner_reader: -> { 'Owner' }, actor: actor, account_events: session.actor_events)
    lease = context.capture
    selection = {match_id: match_id}.freeze
    screen = T::LocalFixedTeamExecutionScreen.allocate
    screen.instance_variable_set(:@program, program)
    screen.instance_variable_set(:@context, context)
    screen.instance_variable_set(:@lease, lease)
    screen.define_singleton_method(:selectors) { selection }
    screen.define_singleton_method(:current?) { context.current?(lease) }
    submitted = nil
    screen.define_singleton_method(:start_fixed) { |action, **intent| submitted = [action, intent] }
    driver = TournamentNativeDriver.new
    driver.step(GameRoomContent.utf8(GameRoomLocalization.translate('Taboo')), [13])
    screen.send(:consume_game_surface, {private_surface: {state: :confirmed, effect: projection}}, {selection: selection})
    driver.finish
    assert_equal(:local_game_move, submitted&.first)
    assert_equal(projection[:revision], submitted.last[:revision])
    assert_equal('start', submitted.last[:move_selection]['action'])
    assert_equal(projection[:spec].token, submitted.last[:move_selection]['token'])
    submitted.last[:move_selection]
  ensure
    context&.close
    session&.close
    program&.finalize
    own_runtime&.close
    TournamentEntryContextTest::Program.app_runtime = previous_runtime if previous_runtime
  end

  def with_declared_team_backend(fixture, actor)
    directory = File.join(fixture.directory, 'team-plans')
    identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: fixture.tables.backend_identity)
    program = TournamentEntryContextTest::Program.new(directory)
    readiness = T::LocalReadinessSession.new
    readiness.choose_actor(actor)
    readiness.bind_backend(identity)
    owner = -> { fixture.owner }
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: owner,
      account_events: readiness.actor_events)
    authority = readiness.context(program: program, owner_reader: owner, entry: entry, lease: entry.capture,
      actor: actor, identity: identity)
    fixture.actor = actor
    backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: fixture.tables,
      journal: fixture.journal_for(actor), actor: actor, registry: fixture.registry, clock: -> { fixture.now }, context: authority)
    yield backend, authority, directory
  ensure
    authority&.close
    entry&.close
    readiness&.close
    program&.finalize
  end

  def with_declared_team_execution(fixture, record, actor, match_index = 0)
    with_declared_team_backend(fixture, actor) do |backend, authority, directory|
      match = record['evidence']['plan']['matches'].fetch(match_index)
      window = match['windows'].first
      execution = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
        source_identity: fixture.tables.backend_identity, context: authority, registry: fixture.registry,
        clock: -> { window['opens'] + 1 }, policy_ref: 'declared-team-protocol-test', expires_at: window['closes'] - 1)
      execution.native_provider = T::LocalFixedTeamNativeProvider.new(capacity: match['players'].size)
      execution.select(intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: window['id'])
      yield execution, authority
    end
  end

  def start_declared_team_match(fixture, intent_id: 'declared-team-start')
    record = nil
    # Explicit four-person fixture roster.
    with_declared_team_backend(fixture, 'Organizator') do |backend, _authority, _directory|
      record = backend.accept(preview: backend.preview_pairs(publication_ref: fixture.reference,
        pairs: [%w[alice bob], %w[carol dave]], team_template: [0, 1, 0, 1], intent_id: intent_id))
    end
    people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
    people.each { |actor| with_declared_team_execution(fixture, record, actor) { |execution| assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state]) } }
    binding = nil
    with_declared_team_execution(fixture, record, people.first) do |execution|
      assert_equal(:bound, execution.request_match[:state])
      binding = T::CoordinationContract.digest(execution.admission(action: :admission_status)[:status]['binding'])
    end
    people.each do |actor|
      with_declared_team_execution(fixture, record, actor) do |execution|
        consent = execution.admission(action: :consent, binding_digest: binding)[:effect]
        assert_equal(:confirmed, execution.admission(action: :enter, consent_id: consent['id'])[:state])
      end
    end
    with_declared_team_execution(fixture, record, people.first) do |execution|
      assert_equal(:confirmed, execution.local_game(action: :start_local_game, binding_digest: binding)[:state])
    end
    record
  end
end
