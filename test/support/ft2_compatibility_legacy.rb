# encoding: UTF-8
require_relative 'tournament_local_execution_plan'
require_relative 'tournament_local_readiness'
require_relative '../../lib/tournaments/local_execution_plan_backend'
require_relative '../../lib/tournaments/readiness_history'

# Małe historyczne dane powstają w procesie A na przyjętej produkcji1568.
module FT2CompatibilityLegacy
  include TournamentLocalExecutionPlanSupport
  include TournamentLocalReadinessSupport

  def legacy_root
    File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'historyczne1568')
  end

  def exact_files(directory)
    Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { |p| File.file?(p) }.sort.to_h do |path|
      [path.delete_prefix(directory + '/'), File.binread(path).unpack1('H*')]
    end
  end

  def legacy_json(path, value)
    File.open(path, 'wx:UTF-8') { |f| f.write(JSON.pretty_generate(value)) }
  end

  def old_plan(fixture)
    record = fixture.backend.readback(intent_id: 'historyczny')
    {'source' => fixture.author_service.execution_source(publication_ref: fixture.reference),
      'record' => record, 'current' => fixture.backend.current(intent_id: 'historyczny'),
      'requests' => record['evidence']['plan']['matches'].map { |m| request(record, m) }}
  end

  def history_for(backend, directory, context, target)
    history = T::ReadinessHistory.new(directory: directory, context: -> { context }, identity: backend.identity)
    service = T::ReadinessService.new(port: backend, trusted_identity: backend.identity,
      directory: directory, context: -> { context })
    {'plans' => backend.plans, 'snapshot' => backend.snapshot(**target),
      'current' => service.current(**target), 'records' => history.records(**target),
      'gate' => backend.gate_state(**target)}
  end

  def write_legacy
    FileUtils.mkdir_p(legacy_root)
    plans = %w[chess four_in_a_row].to_h do |game|
      f = TournamentLocalExecutionPlanSupport::Fixture.new(File.join(legacy_root, game), game: game)
      begin
        b = f.backend
        b.accept(preview: b.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'historyczny'))
        [game, old_plan(f)]
      ensure
        f.close
      end
    end
    ctx = TournamentLocalWorkspaceSupport::Context.new(File.join(legacy_root, 'k03'))
    data = prepared(ctx)
    ready = data[:service].declare(request: data[:request])
    assert_equal(:confirmed, ready[:state])
    k03 = history_for(data[:backend], data[:directory], data[:context], data[:target])
    k03['receipt'] = data[:backend].lookup(operation: ready[:receipt]['operation'])
    expected = {'pid' => Process.pid, 'plans' => plans, 'k03' => k03,
      'context' => data[:context], 'target' => data[:target], 'files_hex' => exact_files(legacy_root)}
    legacy_json(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'historyczne-expected.json'), expected)
    legacy_json(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'legacy-a.json'), expected)
    puts 'GREEN A1568: rzeczywiste chess/board/K03 utrwalone; bez FT2'
  end

  def read_legacy
    expected = JSON.parse(File.binread(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', 'historyczne-expected.json')))
    assert(Process.pid != expected['pid'], 'Zimny B musi mieć inny PID')
    before = exact_files(legacy_root)
    assert_equal(expected['files_hex'], before, 'Pełne bajty A przed odczytem B')
    refusals = []
    plans = %w[chess four_in_a_row].to_h do |game|
      f = TournamentLocalExecutionPlanSupport::Fixture.new(File.join(legacy_root, game), reopen: true)
      begin
        actual = old_plan(f)
        assert_equal(expected['plans'][game], JSON.parse(JSON.generate(actual)), 'Pełne źródło, rekord, current i requesty obu nóg')
        missing = f.backend.readback(intent_id: 'nieistniejacy-historyczny')
        error = assert_raises(RuntimeError) { assert_equal(expected['plans'][game]['record'], missing, 'Negatywna kontrola utraconego rekordu') }
        refusals << {'game' => game, 'missing' => missing, 'oracle_rejected' => error.message}
        error = assert_raises(T::Publication::Invalid) do
          T::LocalFixedTeamExecutionStorage.new(plan_backend: f.backend, plan_directory: File.join(f.directory, 'k02'),
            source_identity: f.tables.backend_identity, guard: -> {}, registry: GameRoomGames::CATALOG)
        end
        assert_equal(:invalid_composition, error.code, 'Nowa przestrzeń nie przyjmuje starego autorytetu')
        [game, actual]
      ensure
        f.close
      end
    end
    directory = File.join(legacy_root, 'k03')
    ctx = TournamentLocalWorkspaceSupport::Context.new(directory)
    ctx.now = 201
    author = ctx.workspace('Organizator')
    backend = T::LocalReadinessBackend.new(directory: File.join(directory, 'k03'), actor: 'Alicja', clock: -> { 201 },
      source: ->(ref) { author.schedule_candidate(publication_ref: ref) })
    target = expected['target'].transform_keys(&:to_sym)
    k03 = history_for(backend, File.join(directory, 'journal'), expected['context'], target)
    k03['receipt'] = backend.lookup(operation: expected['k03']['receipt']['operation'])
    assert_equal(expected['k03'], JSON.parse(JSON.generate(k03)), 'K03: pełne receipts/IDs/current/history/gate')
    assert_equal(false, k03['gate']['open'])
    missing_op = JSON.parse(JSON.generate(expected['k03']['receipt']['operation']))
    missing_op['operation_id'] = SecureRandom.uuid
    missing_response = backend.lookup(operation: missing_op)
    assert_equal('unknown', missing_response['status'])
    error = assert_raises(RuntimeError) { assert_equal(expected['k03']['receipt'], missing_response, 'Negatywna kontrola braku receipt') }
    refusals << {'k03_missing' => missing_response, 'oracle_rejected' => error.message}
    after = exact_files(legacy_root)
    assert_equal(before, after, 'Żadnego zapisu migracji ani nowych plików/ID')
    legacy_json(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'legacy-b.json'),
      {pid: Process.pid, expected: expected, actual: {plans: plans, k03: k03}, files_after_hex: after, negative_controls: refusals})
    puts 'GREEN B1629: dokładne odczyty chess/board/K03; brak migracji, kontrole negatywne'
  end
end
