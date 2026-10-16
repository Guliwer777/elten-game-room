require_relative 'tournament_dispatch'
require_relative '../../lib/tournaments/local_individual_connection'
module TournamentPhaseConnectionSupport
  include TournamentDispatchSupport
  def with_phase_connection(fixture, actor)
    fixture.actor = actor
    directory = File.join(fixture.directory, 'k02')
    program = TournamentEntryContextTest::Program.new(directory)
    session = T::LocalReadinessSession.new
    session.choose_actor(actor)
    owner = -> { fixture.owner }
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: owner,
      account_events: session.actor_events)
    connection = T::LocalIndividualConnection.new(directory: directory, tables: fixture.tables,
      journal: fixture.journal_for(actor), actor: actor, registry: fixture.registry, clock: -> { fixture.now },
      session: session, program: program, owner_reader: owner, entry: entry, lease: entry.capture)
    yield connection
  ensure
    connection&.close
    entry&.close
    session&.close
    program&.finalize
  end
end
