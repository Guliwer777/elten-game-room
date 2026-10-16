# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
directory = GameRoomTest::TemporaryDirectory.create('s')
fixture = F.fixture(directory)
record = fixture[:record]
deadline = record['evidence']['plan']['matches'].first['windows'].first['closes'] - 60
begin
  %w[Ala Anna Bartek Beata].each do |actor|
    F.with_execution(fixture, actor) do |execution|
      F.select_execution(execution, record)
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  F.with_execution(fixture, 'Ala', expires_at: deadline) do |execution|
    F.select_execution(execution, record)
    assert_equal(:bound, execution.request_match[:state])
    binding = execution.admission(action: :admission_status)[:status]['binding']
    digest = T::CoordinationContract.digest(binding)
    assert_equal(:entries_required, execution.local_game(action: :start_local_game, binding_digest: digest)[:reason])
    assert_equal(:target_changed, execution.local_game(action: :start_local_game, binding_digest: 'other')[:reason])
  end
  %w[Anna Bartek Beata Ala].each do |actor|
    F.with_execution(fixture, actor) do |execution|
      F.select_execution(execution, record)
      status = execution.admission(action: :admission_status)[:status]
      if actor == 'Ala'
        assert_equal(4, status['participants'].size)
        assert_equal(:entries_required, execution.local_game(action: :start_local_game,
          binding_digest: T::CoordinationContract.digest(status['binding']))[:reason])
      end
      consent = execution.admission(action: :consent, binding_digest: T::CoordinationContract.digest(status['binding']))[:effect]
      assert_equal(:confirmed, execution.admission(action: :enter, consent_id: consent['id'])[:state])
    end
  end
  F.with_execution(fixture, 'Ala') do |execution, _backend, session|
    F.select_execution(execution, record)
    digest = T::CoordinationContract.digest(execution.admission(action: :admission_status)[:status]['binding'])
    original_time, fixture[:now] = fixture[:now], deadline
    assert_equal(:stale_grant, execution.local_game(action: :start_local_game, binding_digest: digest)[:reason])
    fixture[:now] = original_time
    session.choose_actor('Anna'); session.choose_actor('Ala')
    assert_equal(:context_changed, execution.local_game(action: :start_local_game, binding_digest: digest)[:reason])
  end
  F.with_execution(fixture, 'Anna') do |execution|
    F.select_execution(execution, record)
    binding = execution.admission(action: :admission_status)[:status]['binding']
    assert_equal(:not_coordinator, execution.local_game(action: :start_local_game, binding_digest: T::CoordinationContract.digest(binding))[:reason])
  end
  F.with_execution(fixture, 'Ala') do |execution|
    F.select_execution(execution, record)
    binding = execution.admission(action: :admission_status)[:status]['binding']
    digest = T::CoordinationContract.digest(binding)
    fault = Module.new do
      def write(document, receipt: nil)
        result = super
        if $start_lose_response && receipt && receipt['kind'] == 'start'
          $start_lose_response = false
          raise GameRoomTournaments::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'lost-start', receipt: receipt)
        end
        result
      end
    end
    T::LocalFixedTeamExecutionStorage.prepend(fault)
    $start_lose_response = true
    uncertain = execution.local_game(action: :start_local_game, binding_digest: digest)
    assert_equal(:uncertain, uncertain[:state])
    readback = execution.local_game(action: :local_game_status)
    assert_equal(uncertain[:receipt], readback[:status]['receipt'])
    result = execution.local_game(action: :start_local_game, binding_digest: digest)
    assert_equal(:confirmed, result[:state])
    assert_equal('awaiting_deal', result[:status]['phase'])
    assert_equal(0, result[:status]['event_count'])
    assert_equal(result[:effect], execution.local_game(action: :start_local_game, binding_digest: digest)[:effect])
    assert_equal(:bound, execution.reconcile[:state])
    expected = record['evidence']['plan']['matches'].first['players'].sort_by { |p| p['seat'] }.map { |p| p['username'] }
    assert_equal(expected, result[:status]['players'])
    execution.revoke_coordinator(expected_epoch: execution.coordinator_epoch)
    assert_equal(result[:effect], execution.local_game(action: :start_local_game, binding_digest: digest)[:effect])
  end
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  state_path = File.join(fixture[:plans], 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  File.write(File.expand_path('../../tmp/start-live-fixture-path.txt', __dir__), state_path)
  bytes = File.binread(state_path)
  document = JSON.parse(bytes)
  assert_equal(1, document['executions'].values.count { |r| r['start'] })
  assert_equal(1, document['native']['cores'].flat_map { |r| r['entries'] }.count { |r| r.dig('packet', 'kind') == 'game_started' })
  document['executions'].values.find { |r| r['start'] }['start']['session_id'] += 1
  File.binwrite(state_path, JSON.generate(document))
  begin
    F.with_execution(fixture, 'Anna') do |execution|
      F.select_execution(execution, record, history: true)
      begin
        execution.local_game(action: :local_game_status)
        raise 'Accepted a corrupted Start proof'
      rescue T::Publication::Invalid => error
        assert_equal(:sandbox_corrupt, error.code)
      end
    end
  ensure
    File.binwrite(state_path, bytes)
  end
  fixture[:now] = deadline
  F.with_execution(fixture, 'Anna') do |execution|
    F.select_execution(execution, record, history: true)
    assert_equal('awaiting_deal', execution.local_game(action: :local_game_status)[:status]['phase'])
  end
  cold_script = File.expand_path('../support/tournament_start_cold_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, '-EUTF-8', cold_script, directory, fixture[:now].to_s], err: [:child, :out], &:read)
  assert($?.success?, "Cold Start failed: #{output}")
  assert(output.include?('PASS cold Start'), 'No cold Start evidence')
  puts 'PASS Start: complete admissions, exact target, owner, single native session, real Spades replay, history, corruption'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
