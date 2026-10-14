# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = GameRoomTournaments
U = TournamentFT2B1UI
mode = ARGV.fetch(0, 'native')
raise 'Podaj native|boundary' unless %w[native boundary].include?(mode)
fixture = U.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
results = []
connection = entry = session = observer = fail_at = nil
begin
  if mode == 'native'
    GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
    driver = TournamentNativeDriver.new
    hub = T::LocalTestHub.new(**F.args(fixture))
    U.enter(driver)
    driver.step('Accepted fixed-team plans') do |form|
      F.button(form, 'Check status').press; U.complete(hub, form)
      form.fields.first.index = 1; form.fields.first.trigger(:move); U.complete(hub, form)
      matches = F.field(form, 'My fixed-team matches')
      matches.index = 2; matches.trigger(:move); U.complete(hub, form)
      windows = F.field(form, 'Execution window')
      windows.index = 1; windows.trigger(:move); U.complete(hub, form)
      screen = U.screen(hub)
      previous = screen.controller.view
      selection = screen.send(:selectors)
      cursors = [form.index, form.fields.first.index, matches.index, windows.index]
      detail = screen.send(:match_text, screen.controller.view[:matches][matches.index])
      original = File.binread(fixture[:plan_file])
      document = JSON.parse(original)
      document['records'].first['evidence']['plan_digest'] = '0' * 64
      File.binwrite(fixture[:plan_file], JSON.generate(document))
      before = U.snapshot(fixture[:sandbox])
      error = nil
      begin
        F.button(form, 'Check status').press; U.complete(hub, form)
      rescue Exception => caught
        error = caught
      end
      result = {error: error && [error.class.name, error.message], reason: screen.controller.reason,
        same_model: screen.controller.view.equal?(previous), selected_id: screen.controller.view[:selected_id],
        selection: screen.send(:selectors), cursors: [form.index, form.fields.first.index, matches.index, windows.index],
        details: screen.send(:match_text, screen.controller.view[:matches][matches.index]), status: F.field(form, 'Fixed-team execution status').text,
        disk_unchanged: before == U.snapshot(fixture[:sandbox])}
      results << result
      U.evidence('catalog-corruption', results)
      assert_equal(nil, error, 'R01: błąd dokumentu nie może ominąć natywnego Status')
      assert_equal(:sandbox_corrupt, screen.controller.reason)
      assert(result[:same_model])
      assert_equal(previous[:selected_id], result[:selected_id])
      assert_equal(selection, result[:selection]); assert_equal(cursors, result[:cursors]); assert_equal(detail, result[:details])
      assert(result[:status].include?('The accepted fixed-team storage is damaged or incompatible. The last valid view is retained; no data was replaced.'))
      assert(result[:disk_unchanged])
    end
    U.leave(driver)
    hub.run; driver.finish
  else
    program = fixture[:program]
    workspace = T::LocalWorkspace.new(**F.args(fixture).reject { |k, _| k == :confirm }, actor: 'Ala')
    directory = workspace.fixed_team_plan_directory
    tables = workspace.instance_variable_get(:@provider)
    journal = workspace.instance_variable_get(:@journal)
    identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: tables.backend_identity)
    [:pre, :post].each do |phase|
      [T::Publication::Invalid.new(:niezgodny_digest_planu), T::Publication::Invalid.new(:invalid_fields),
        NoMethodError.new('ProgramError czytnika'), IOError.new('IOError czytnika')].each do |primary|
        # Fresh real context per one-shot fault: Invalid invalidates the old lease.
        session = T::LocalReadinessSession.new
        session.choose_actor('Ala'); session.bind_backend(identity)
        reads = 0
        fail_at = nil
        cause = ArgumentError.new('Przyczyna czytnika')
        primary.set_backtrace(['owner_reader_fix1.rb:1'])
        reader = lambda do
          reads += 1
          raise primary, cause: cause if reads == fail_at
          F::OWNER
        end
        entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
          owner_reader: reader, account_events: session.actor_events)
        connection = T::LocalFixedTeamConnection.new(directory: directory, tables: tables, journal: journal,
          actor: 'Ala', registry: F::REGISTRY, clock: -> { fixture[:now] }, session: session,
          program: program, owner_reader: reader, entry: entry, lease: entry.capture)
        backend = connection.instance_variable_get(:@backend)
        phases = {}
        observer = TracePoint.new(:call, :return) { |event| phases[event.event] = reads }
        observer.enable(target: backend.method(:validate_document!), target_thread: nil)
        reads = 0
        assert_equal(:accepted, connection.catalog[:reason])
        observer.disable
        baseline = U.snapshot(fixture[:sandbox])
        reads = 0
        fail_at = phases.fetch(phase == :pre ? :call : :return) + (phase == :pre ? 0 : 1)
        observed = value = nil
        begin
          value = connection.catalog
        rescue Exception => caught
          observed = caught
        end
        fail_at = nil
        connection.close; entry.close; session.close
        results << {phase: phase, phases: phases, type: primary.class.name, code: primary.respond_to?(:code) ? primary.code : nil,
          same_primary: observed.equal?(primary), same_cause: observed && observed.cause.equal?(cause),
          observed_code: observed.respond_to?(:code) ? observed.code : nil,
          backtrace: observed&.backtrace, result_state: value && value[:state], result_reason: value && value[:reason],
          read_error_same: value && value[:read_error].equal?(primary), reads: reads,
          registries: [program.managed_resources.size, program.class.app_runtime.managed_resources.size],
          listeners: [session.actor_events.listener_count, session.backend_events.listener_count]}
        assert_equal(baseline, U.snapshot(fixture[:sandbox]))
        assert_equal([0, 0], results.last[:registries]); assert_equal([0, 0], results.last[:listeners])
      end
    end
    U.evidence('catalog-boundary', {results: results})
    assert(results.all? { |r| r[:same_primary] && r[:same_cause] && r[:backtrace] == ['owner_reader_fix1.rb:1'] }, 'R01: czytnik pre/post został przeklasyfikowany jako błąd magazynu')
  end
  puts "PASS R01 #{mode}"
ensure
  fail_at = nil
  observer&.disable
  connection&.close; entry&.close; session&.close
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end
