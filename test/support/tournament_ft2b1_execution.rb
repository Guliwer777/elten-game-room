# encoding: UTF-8
require_relative 'tournament_ft2b1_entry'
require_relative '../../lib/tournaments/local_fixed_team_execution'

module TournamentFT2B1
  module_function
  def with_execution(fixture, actor, expires_at: nil, provider: :production)
    registry = fixture.fetch(:registry, REGISTRY)
    program = fixture[:program]
    owner = T::LocalTestDialogs::Owner.new(-> { OWNER }, ->(message) { raise message })
    workspace = T::LocalWorkspace.new(**args(fixture).reject { |k, _| k == :confirm }, actor: actor)
    directory = workspace.fixed_team_plan_directory
    tables = workspace.instance_variable_get(:@provider)
    journal = workspace.instance_variable_get(:@journal)
    identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: tables.backend_identity)
    session = T::LocalReadinessSession.new
    session.choose_actor(actor); session.bind_backend(identity)
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: owner.method(:current), account_events: session.actor_events)
    authority = session.context(program: program, owner_reader: owner.method(:current), entry: entry, lease: entry.capture, actor: actor, identity: identity)
    begin
      backend = T::LocalFixedTeamPlanBackend.new(directory: directory, tables: tables, journal: journal, actor: actor,
        registry: registry, clock: -> { fixture[:now] }, context: authority)
      execution = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory, source_identity: tables.backend_identity,
        context: authority, registry: registry, clock: -> { fixture[:now] }, policy_ref: T::LocalFixedTeamConnection::POLICY, expires_at: expires_at)
      if provider == :production
        provider = T.const_defined?(:LocalFixedTeamNativeProvider, false) ? T::LocalFixedTeamNativeProvider.new : nil
      end
      execution.native_provider = provider
      yield execution, backend, session, entry
    ensure
      authority.close; entry.close; session.close
    end
  end

  def select_execution(execution, record, index = 0, history: false)
    match = record['evidence']['plan']['matches'].fetch(index)
    execution.public_send(history ? :select_for_reconcile : :select, intent_id: record['preview']['intent_id'],
      match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
  end
end
