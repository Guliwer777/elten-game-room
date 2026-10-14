# encoding: UTF-8
require_relative 'tournament_fixed_teams'
require_relative 'tournament_entry_context'
require_relative '../../lib/tournaments/local_fixed_team_plan_backend'
require_relative '../../lib/tournaments/readiness_service'

# Wyłącznie własne konto próbne i rzeczywiste źródła publikacji/FT1.
module TournamentFixedTeamExecutionSupport
  include TournamentFixedTeamsSupport

  def execution_fixture(name, template: [0, 0, 1, 1])
    directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', name)
    context, service, reference = fixture(directory: directory)
    source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: template)
    record = nil
    with_backend(context) do |backend|
      shown = backend.preview(publication_ref: reference, membership: membership, team_template: template,
        base_seats: bases(source, template), intent_id: 'ft2a-plan')
      record = backend.accept(preview: shown)
      assert_equal(record, backend.current(intent_id: 'ft2a-plan'))
    end
    [context, record]
  end

  def actor_backend(context, actor, owner_reader: nil)
    directory = File.join(context.directory, 'plany')
    identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: context.provider.backend_identity)
    program = TournamentEntryContextTest::Program.new(directory)
    session = T::LocalReadinessSession.new
    session.choose_actor(actor)
    session.bind_backend(identity)
    reader = owner_reader || -> { 'WlascicielPlikow' }
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: reader,
      account_events: session.actor_events)
    authority = session.context(program: program, owner_reader: reader, entry: entry, lease: entry.capture,
      actor: actor, identity: identity)
    context.actor = actor
    backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: context.provider,
      journal: context.reopen_journal(actor: actor), actor: actor, registry: REGISTRY, clock: -> { context.now }, context: authority)
    yield backend, authority, directory, session, program, entry
  ensure
    authority&.close
    entry&.close
    session&.close
    program&.finalize
    program&.class&.app_runtime&.close
  end

  def execution_for(context, record, actor, native_provider: nil)
    actor_backend(context, actor) do |backend, authority, directory, session, program, entry|
      facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
        source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
        clock: -> { record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1 },
        policy_ref: 'jawna-polityka-proby-ft2a', expires_at: record['evidence']['plan']['matches'].first['windows'].first['closes'] - 1)
      facade.native_provider = native_provider if native_provider && facade.respond_to?(:native_provider=)
      yield facade, session, program, entry
    end
  end

  def select_match(facade, record, index = 0)
    match = record['evidence']['plan']['matches'].fetch(index)
    facade.select(intent_id: 'ft2a-plan', match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
  end
end
