# encoding: UTF-8
require_relative '../support/temporary_directory'
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
directory = GameRoomTest::TemporaryDirectory.create('a')
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
  end
  F.with_execution(fixture, 'Anna') do |execution|
    F.select_execution(execution, record)
    status = execution.admission(action: :admission_status).fetch(:status)
    assert_equal(nil, status['consent'])
    assert_equal(nil, status['entry'])
    assert_equal(1, status['participants'].size)
    assert_equal(:consent_required, execution.admission(action: :enter, consent_id: 'unapproved')[:reason])
    assert_equal(:target_changed, execution.admission(action: :consent, binding_digest: 'other-target')[:reason])
    digest = T::CoordinationContract.digest(status['binding'])
    consent = execution.admission(action: :consent, binding_digest: digest)
    assert_equal(:confirmed, consent[:state])
    assert_equal(1, consent[:status]['participants'].size)
    id = consent[:effect]['id']
    receipt = execution.admission(action: :enter, consent_id: id)
    assert_equal(:confirmed, receipt[:state])
    assert_equal('joined', receipt[:effect]['status'])
    assert_equal(2, receipt[:status]['participants'].size)
    person = record['evidence']['plan']['matches'].first['players'].find { |p| p['account'] == 'anna' }
    assert_equal(person.values_at('seat', 'team'), receipt[:effect].values_at('seat', 'team'))
    assert_equal(receipt[:effect], execution.admission(action: :enter, consent_id: id)[:effect])
    assert_equal(2, execution.admission(action: :admission_status)[:status]['participants'].size)
    # Reconciliation still reads the immutable creation proof after joining.
    assert_equal(:bound, execution.reconcile[:state])
  end
  F.with_execution(fixture, 'Beata') do |execution|
    F.select_execution(execution, record)
    own = execution.admission(action: :admission_status)[:status]
    consent = execution.admission(action: :consent, binding_digest: T::CoordinationContract.digest(own['binding']))[:effect]
    fault = Module.new do
      def write(document, receipt: nil)
        result = super
        if $admission_lose_response && receipt && receipt['kind'] == 'entry'
          $admission_lose_response = false
          raise GameRoomTournaments::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'lost-response', receipt: receipt)
        end
        result
      end
    end
    T::LocalFixedTeamExecutionStorage.prepend(fault)
    $admission_lose_response = true
    uncertain = execution.admission(action: :enter, consent_id: consent['id'])
    assert_equal(:uncertain, uncertain[:state])
    readback = execution.admission(action: :admission_status)[:status]
    assert_equal(uncertain[:receipt], readback['entry'])
    assert_equal(3, readback['participants'].size)
  end
  # Fresh context reads its receipt; another person cannot use that consent.
  F.with_execution(fixture, 'Bartek') do |execution, _backend, session|
    F.select_execution(execution, record)
    status = execution.admission(action: :admission_status)[:status]
    assert_equal(nil, status['consent'])
    assert_equal(:consent_required, execution.admission(action: :enter, consent_id: 'not-mine')[:reason])
    session.choose_actor('Celina')
    session.choose_actor('Bartek')
    assert_equal(:context_changed, execution.admission(action: :consent,
      binding_digest: T::CoordinationContract.digest(status['binding']))[:reason])
  end
  original_time, fixture[:now] = fixture[:now], deadline
  F.with_execution(fixture, 'Bartek') do |execution|
    F.select_execution(execution, record)
    status = execution.admission(action: :admission_status)[:status]
    assert_equal(false, status['current'])
    assert_equal(:stale_grant, execution.admission(action: :consent,
      binding_digest: T::CoordinationContract.digest(status['binding']))[:reason])
  end
  fixture[:now] = original_time
  F.with_execution(fixture, 'Ala') do |execution|
    F.select_execution(execution, record)
    status = execution.admission(action: :admission_status)[:status]
    consent = execution.admission(action: :consent, binding_digest: T::CoordinationContract.digest(status['binding']))[:effect]
    assert_equal('already_here', execution.admission(action: :enter, consent_id: consent['id'])[:effect]['status'])
    assert_equal(3, execution.admission(action: :admission_status)[:status]['participants'].size)
    execution.revoke_coordinator(expected_epoch: execution.coordinator_epoch)
    assert_equal(false, execution.admission(action: :admission_status)[:status]['current'])
    assert_equal(:stale_grant, execution.admission(action: :enter, consent_id: consent['id'])[:reason])
  end
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  state_path = File.join(fixture[:plans], 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  File.write(File.expand_path('../../tmp/admission-live-fixture-path.txt', __dir__), state_path)
  cold_script = File.expand_path('../support/tournament_admission_cold_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, '-EUTF-8', cold_script, directory, fixture[:now].to_s], err: [:child, :out], &:read)
  assert($?.success?, "Cold admission failed: #{output}")
  assert(output.include?('PASS cold admission'), 'No cold readback evidence')
  bytes = File.binread(state_path)
  document = JSON.parse(bytes)
  poisoned = JSON.parse(bytes)
  poisoned['executions'].values.find { |e| e['admission'] }['admission']['entries']['anna']['seat'] = 99
  File.binwrite(state_path, JSON.generate(poisoned))
  begin
    F.with_execution(fixture, 'Anna') do |execution|
      F.select_execution(execution, record, history: true)
      failure = nil
      begin
        execution.admission(action: :admission_status)
      rescue T::Publication::Invalid => error
        failure = error.code
      end
      assert_equal(:sandbox_corrupt, failure)
    end
    assert_equal(Digest::SHA256.hexdigest(JSON.generate(poisoned)), Digest::SHA256.file(state_path).hexdigest)
  ensure
    File.binwrite(state_path, bytes)
  end
  # A participant's endpoint can reopen only after an actual membership receipt.
  native = T::LocalFixedTeamNativeEndpoint.new(state: document['native'], owner: 'Anna', clock: T::LocalFixedTeamNativeProvider::Clock.new)
  assert_equal(1, native.sessions.size)
  assert_equal(false, native.sessions.first.owner?)
  assert_equal(3, native.sessions.first.participants.size)
  native.close_view
  puts 'PASS admission: own consent, exact seat/membership, idempotency, lost response, historical proof, revoked epoch'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
