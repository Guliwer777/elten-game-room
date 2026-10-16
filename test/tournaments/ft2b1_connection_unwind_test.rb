# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = GameRoomTournaments
U = TournamentFT2B1UI
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
program = fixture[:program]
results = []
begin
  workspace = T::LocalWorkspace.new(**F.args(fixture).reject { |k, _| k == :confirm }, actor: 'Ala')
  directory = workspace.fixed_team_plan_directory
  tables = workspace.instance_variable_get(:@provider)
  journal = workspace.instance_variable_get(:@journal)
  session = T::LocalReadinessSession.new
  session.choose_actor('Ala')
  identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: tables.backend_identity)
  session.bind_backend(identity)
  armed = false
  token = Object.new
  reader = lambda do
    if armed
      armed = false
      throw :fix1_constructor, token
    end
    F::OWNER
  end
  entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
    owner_reader: reader, account_events: session.actor_events)
  options = {directory: directory, tables: tables, journal: journal, actor: 'Ala', registry: F::REGISTRY,
    clock: -> { fixture[:now] }, session: session, program: program, owner_reader: reader, entry: entry, lease: entry.capture}
  counts = -> { [program.managed_resources.size, program.class.app_runtime.managed_resources.size,
    session.actor_events.listener_count, session.backend_events.listener_count] }
  baseline = counts.call
  assert_equal([1, 1, 1, 0], baseline)
  healthy = T::LocalFixedTeamConnection.new(**options)
  assert_equal([2, 2, 2, 1], counts.call, 'Ukończona konstrukcja musi utrzymać własny context')
  assert_equal(:accepted, healthy.catalog[:reason])
  healthy.close; healthy.close
  assert_equal(baseline, counts.call)
  # Arm only after the real context returned: the resource belongs to connection now.
  original_context = session.method(:context)
  session.define_singleton_method(:context) do |**args|
    value = original_context.call(**args)
    armed = true
    value
  end
  result = catch(:fix1_constructor) do
    T::LocalFixedTeamConnection.new(**options)
    :unexpected_success
  end
  after_throw = counts.call
  results << {kind: 'throw', same_token: result.equal?(token), before: baseline, after: after_throw}
  U.evidence('connection-unwind', results)
  assert(result.equal?(token), 'Throw musi dojść do tego samego catch z tą samą wartością')
  assert_equal(baseline, after_throw, 'Nieukończona konstrukcja zatrzymała własny context')
  session.define_singleton_method(:context, original_context)
  # An ambient rescued exception must not be resurrected on the healthy path.
  ambient = IOError.new('Obsłużony wyjątek wywołującego')
  begin
    raise ambient
  rescue IOError
    retry_connection = T::LocalFixedTeamConnection.new(**options)
    assert_equal([2, 2, 2, 1], counts.call)
    assert_equal(:accepted, retry_connection.catalog[:reason])
    retry_connection.close; retry_connection.close
  end
  assert_equal(baseline, counts.call)
  [:exception, :throw].each do |mode|
    cleanup_fault = false
    secondary = IOError.new('Wtórny release po pierwotnym throw')
    release = program.method(:release)
    program.define_singleton_method(:release) do |val|
      res = release.call(val)
      if cleanup_fault
        cleanup_fault = false
        raise secondary, cause: nil if mode == :exception
        throw :review_secondary_throw, :secondary_token if mode == :throw
      end
      res
    end
    session.define_singleton_method(:context) do |**args|
      val = original_context.call(**args)
      armed = true
      val
    end
    sec_token = Object.new
    reader_sec = lambda do
      if armed
        armed = false
        cleanup_fault = true
        throw :fix1_constructor_sec, sec_token
      end
      F::OWNER
    end
    entry_sec = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
      owner_reader: reader_sec, account_events: session.actor_events)
    options_sec = options.merge(owner_reader: reader_sec, entry: entry_sec, lease: entry_sec.capture)
    secondary_baseline = counts.call
    sec_result = catch(:fix1_constructor_sec) do
      catch(:review_secondary_throw) do
        T::LocalFixedTeamConnection.new(**options_sec)
        :unexpected_success
      end
    end
    assert(sec_result.equal?(sec_token), "Mode #{mode}: Pierwotny token musi być zachowany mimo wtórnego błędu cleanup")
    assert_equal(secondary_baseline, counts.call, "Mode #{mode}: Nieukończona konstrukcja z błędem cleanup musi zwolnić własny context")
    entry_sec.close
    assert_equal(baseline, counts.call, "Mode #{mode}: Zamknięcie wejścia musi zwolnić jego osobne zasoby")
    session.define_singleton_method(:context, original_context)
    program.define_singleton_method(:release, release)
  end
  entry.close; entry.close; session.close; session.close
  assert_equal([0, 0, 0, 0], counts.call)
  results << {kind: 'healthy_after_failure_and_ambient', after: counts.call}
  U.evidence('connection-unwind', results)
  puts 'PASS throw identity, partial/complete constructor, exact Registry/listeners, healthy retry, ambient rescue, repeated close'
ensure
  armed = false
  entry&.close; session&.close
  program.finalize; program.class.app_runtime.close
end
