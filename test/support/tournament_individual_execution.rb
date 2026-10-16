require_relative 'tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_individual_execution'
module TournamentIndividualExecutionSupport
  include TournamentLocalExecutionPlanSupport
  def future_individual_registry
    future = Class.new(GameRoomGames::TicTacToe) do
      def id; 'future_individual'; end
    end
    GameRoomGames::Registry.new([future])
  end
  def with_individual_execution(fixture, record, actor, registry: fixture.registry, clock: nil, execution_class: T::LocalIndividualExecution)
    plans = File.join(fixture.directory, 'k02')
    identity = T::LocalExecutionPlanBackend.identity(directory: plans, source_identity: fixture.tables.backend_identity)
    program = TournamentEntryContextTest::Program.new(plans)
    session = T::LocalReadinessSession.new
    session.choose_actor(actor)
    session.bind_backend(identity)
    owner = -> { fixture.owner }
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: owner,
      account_events: session.actor_events)
    authority = session.context(program: program, owner_reader: owner, entry: entry, lease: entry.capture,
      actor: actor, identity: identity)
    fixture.actor = actor
    backend = fixture.backend(context: authority, registry: registry)
    match = record['evidence']['plan']['matches'].first
    window = match['windows'].first
    execution = execution_class.new(plan_backend: backend, plan_directory: plans,
      source_identity: fixture.tables.backend_identity, context: authority, registry: registry,
      clock: clock || -> { window['opens'] + 1 }, policy_ref: 'individual-technical-test-v1', expires_at: window['closes'] - 1)
    execution.native_provider = T::IndividualNativeProvider.new(capacity: match['players'].size)
    execution.select(intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: window['id'])
    yield execution, authority, session
  ensure
    authority&.close
    entry&.close
    session&.close
    program&.finalize
  end

  def start_individual_match(fixture, intent_id: 'individual-start', execution_class: T::LocalIndividualExecution)
    backend = fixture.backend
    record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
      base_seats: fixture.base, intent_id: intent_id))
    people = record['evidence']['plan']['matches'].first['players'].map { |person| person['username'] }
    people.each do |actor|
      with_individual_execution(fixture, record, actor, execution_class: execution_class) { |e| assert_equal(:confirmed, e.declare(availability: 'ready', expected_revision: 0)[:state]) }
    end
    digest = nil
    with_individual_execution(fixture, record, people.first, execution_class: execution_class) do |e|
      result = e.request_match
      assert_equal(:bound, result[:state], result.inspect)
      digest = T::CoordinationContract.digest(e.admission(action: :admission_status)[:status]['binding'])
    end
    people.each do |actor|
      with_individual_execution(fixture, record, actor, execution_class: execution_class) do |e|
        consent = e.admission(action: :consent, binding_digest: digest)[:effect]
        assert_equal(:confirmed, e.admission(action: :enter, consent_id: consent['id'])[:state])
      end
    end
    with_individual_execution(fixture, record, people.first, execution_class: execution_class) do |e|
      assert_equal(:confirmed, e.local_game(action: :start_local_game, binding_digest: digest)[:state])
    end
    record
  end
end
