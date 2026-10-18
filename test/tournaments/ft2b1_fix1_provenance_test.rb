# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja pochodzenia FT2B1'); super(value, message); end
F = TournamentFT2B1
T = GameRoomTournaments
U = TournamentFT2B1UI
class Fix1ProgramError < Exception; end
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
program = fixture[:program]
workspace = T::LocalWorkspace.new(**F.args(fixture).reject { |k, _| k == :confirm }, actor: 'Ala')
directory = workspace.fixed_team_plan_directory
tables = workspace.instance_variable_get(:@provider)
journal = workspace.instance_variable_get(:@journal)
identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: tables.backend_identity)
results = []
connection = entry = session = observer = nil
armed = false
begin
  [:pre, :post].product([false, true]).each do |phase, with_cause|
    [T::Publication::Invalid.new(:invalid_fields), T::Publication::Invalid.new(:niezgodny_digest_planu),
      IOError.new('Błąd czytnika'), Errno::EIO.new('Błąd systemowy czytnika'), Fix1ProgramError.new('Błąd programu')].each do |primary|
      session = T::LocalReadinessSession.new
      session.choose_actor('Ala'); session.bind_backend(identity)
      reads = 0
      fail_at = nil
      cause = with_cause ? ArgumentError.new('Przyczyna') : nil
      primary.set_backtrace(['pochodzenie-czytnik:19'])
      reader = -> { reads += 1; raise primary, cause: cause if reads == fail_at; F::OWNER }
      entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: reader, account_events: session.actor_events)
      connection = T::LocalFixedTeamConnection.new(directory: directory, tables: tables, journal: journal, actor: 'Ala',
        registry: F::REGISTRY, clock: -> { fixture[:now] }, session: session, program: program, owner_reader: reader, entry: entry, lease: entry.capture)
      backend = connection.instance_variable_get(:@backend)
      phases = {}
      # Probe the first accepted-record read, not the later progress reads.
      observer = TracePoint.new(:call, :return) { |event| phases[event.event] ||= reads }
      observer.enable(target: backend.method(:validate_document!), target_thread: nil)
      reads = 0
      assert_equal(:accepted, connection.catalog[:reason])
      observer.disable
      before = U.snapshot(fixture[:sandbox])
      reads = 0
      fail_at = phases.fetch(phase == :pre ? :call : :return) + (phase == :pre ? 0 : 1)
      observed = value = nil
      begin
        value = connection.catalog
      rescue Exception => caught
        observed = caught
      end
      results << {kind: 'reader', phase: phase, type: primary.class.name, with_cause: with_cause,
        same: observed.equal?(primary), cause: observed && observed.cause.equal?(cause), backtrace: observed&.backtrace,
        reads: reads, fail_at: fail_at, result: value && value[:reason]}
      fail_at = nil
      assert_equal(before, U.snapshot(fixture[:sandbox]))
      assert_equal(:accepted, connection.catalog[:reason], 'Stan pochodzenia wyciekł do następnego odczytu')
      connection.close; entry.close; session.close
      assert_equal([0, 0], [program.managed_resources.size, program.class.app_runtime.managed_resources.size])
      assert_equal([0, 0], [session.actor_events.listener_count, session.backend_events.listener_count])
    end
  end
  U.evidence('provenance-reader', results)
  assert(results.all? { |r| r[:same] && r[:cause] && r[:backtrace] == ['pochodzenie-czytnik:19'] && r[:reads] == r[:fail_at] }, 'Guard/callback został uznany za dane')

  # Ta sama klasa błędu, lecz jawnie pochodząca z czytania lub semantyki danych.
  [false, true].product([:read, :validate]).each do |with_cause, phase|
    session = T::LocalReadinessSession.new
    session.choose_actor('Ala'); session.bind_backend(identity)
    secondary = -> { raise Fix1ProgramError, 'Wtórny postguard' if armed; F::OWNER }
    entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: secondary, account_events: session.actor_events)
    connection = T::LocalFixedTeamConnection.new(directory: directory, tables: tables, journal: journal, actor: 'Ala', registry: F::REGISTRY,
      clock: -> { fixture[:now] }, session: session, program: program, owner_reader: secondary, entry: entry, lease: entry.capture)
    backend = connection.instance_variable_get(:@backend)
    storage = backend.instance_variable_get(:@storage)
    target, method = phase == :read ? [storage, :read_document] : [backend, :validate_document!]
    original = target.method(method)
    [T::Publication::Invalid.new(:invalid_fields), T::Publication::Invalid.new(:niezgodny_digest_planu),
      IOError.new('Awaria danych'), Errno::EIO.new('Awaria odczytu')].each do |primary|
      cause = with_cause ? ArgumentError.new('Przyczyna danych') : nil
      primary.set_backtrace(['pochodzenie-dane:73'])
      target.define_singleton_method(method) do |*args|
        original.call(*args)
        armed = phase == :validate
        raise primary, cause: cause
      end
      before = U.snapshot(fixture[:sandbox])
      value = connection.catalog
      armed = false
      assert_equal(:read_failed, value[:state])
      assert_equal(primary.is_a?(T::Publication::Invalid) ? :sandbox_corrupt : :read_failed, value[:reason])
      assert(value[:read_error].equal?(primary), 'Diagnostyka nie zachowała primary danych')
      assert(primary.cause.equal?(cause)); assert_equal(['pochodzenie-dane:73'], primary.backtrace)
      assert_equal(before, U.snapshot(fixture[:sandbox]))
      # Legacy nie dostaje opakowania katalogu.
      observed = nil
      begin
        backend.accepted_records
      rescue Exception => caught
        observed = caught
      ensure
        armed = false
      end
      assert(observed.equal?(primary)); assert(observed.cause.equal?(cause))
      results << {kind: 'data', phase: phase, type: primary.class.name, with_cause: with_cause, reason: value[:reason], primary: true, legacy: true}
    end
    target.define_singleton_method(method, original)
    begin
      raise IOError, 'Wcześniej obsłużony wyjątek'
    rescue IOError
      assert_equal(:accepted, connection.catalog[:reason], 'Zdrowy odczyt wskrzesił ambient $!')
    end
    connection.close; entry.close; session.close
  end
  # Primary walidatora pozostaje oryginałem również przy throw w postguard
  # i zamykaniu własnego pliku; stan opcji nie przechodzi do legacy.
  [:exception, :throw].product([false, true]).each do |mode, with_cause|
    GameRoomTest::TemporaryDirectory.create('fix1-primary-') do |path|
      active = false
      cause = with_cause ? ArgumentError.new('Przyczyna primary') : nil
      primary = T::Publication::Invalid.new(:invalid_fields)
      primary.set_backtrace(['primary-dane:1'])
      secondary = -> { mode == :throw ? throw(:fix1_secondary, :zly_wynik) : raise(Fix1ProgramError, 'Wtórny cleanup') }
      storage = T::LocalExecutionPlanStorage.new(directory: path, guard: -> { secondary.call if active })
      storage.access(validate: ->(_) {}) { storage.write({'legal' => true}) }
      before = File.binread(storage.path)
      handles = []
      opening = File.method(:open)
      File.define_singleton_method(:open) do |name, *args, &block|
        file = opening.call(name, *args)
        if name.start_with?(path)
          handles << file
          closing = file.method(:close)
          file.define_singleton_method(:close) { closing.call; secondary.call if active }
        end
        block ? block.call(file) : file
      end
      observed = nil
      begin
        result = catch(:fix1_secondary) do
          begin
            storage.access(validate: ->(_) { active = true; raise primary, cause: cause }, read_failure: T::LocalFixedTeamPlanBackend::CatalogReadError) { raise 'Nie wolno zwrócić danych' }
          rescue T::LocalFixedTeamPlanBackend::CatalogReadError => error
            observed = error.cause
          end
        end
        assert(result != :zly_wynik, 'Wtórny throw wygrał z primary')
      ensure
        active = false
        File.define_singleton_method(:open, opening)
      end
      assert(observed.equal?(primary)); assert(observed.cause.equal?(cause)); assert_equal(['primary-dane:1'], observed.backtrace)
      assert(!handles.empty? && handles.all?(&:closed?), 'Własne uchwyty nie zostały zamknięte')
      assert_equal(nil, storage.instance_variable_get(:@read_provenance))
      storage.access(validate: ->(_) {}) { |document| assert_equal({'legal' => true}, document) }
      assert_equal(before, File.binread(storage.path))
      token = Object.new
      result = catch(:fix1_plain_throw) do
        storage.access(validate: ->(_) { throw :fix1_plain_throw, token }, read_failure: T::LocalFixedTeamPlanBackend::CatalogReadError) { raise 'Nie wolno zwrócić danych' }
      end
      assert(result.equal?(token)); assert_equal(nil, storage.instance_variable_get(:@read_provenance))
      legacy = assert_raises(T::Publication::Invalid) { storage.access(validate: ->(_) { raise primary, cause: cause }) {} }
      assert(legacy.equal?(primary))
      results << {kind: 'cleanup', mode: mode, with_cause: with_cause, primary: true, closed: handles.size, state_cleared: true, legacy: true, throw_token: true}
    end
  end
  U.evidence('provenance', results)
  puts 'PASS pochodzenie: reader pre/post, nil/istniejący cause, Invalid/IO/SystemCall/ProgramError, dane/legacy/primary/ambient'
ensure
  armed = false
  observer&.disable
  connection&.close; entry&.close; session&.close
  program.finalize; program.class.app_runtime.close
end
