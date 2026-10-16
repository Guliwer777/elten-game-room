require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta]) do |fixture|
  record = start_individual_match(fixture)
  envelope = older = nil
  state_path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  public_bytes = File.binread(state_path)
  session_id = JSON.parse(public_bytes)['executions'].values.first['start']['session_id']
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    vault = execution.private_choices
    older = vault.prepare(session_id: session_id, round_id: 'round-1', user: 'Alpha', payload: {'answer' => 'old-secret'})
    envelope = vault.prepare(session_id: session_id, round_id: 'round-1', user: 'Alpha', payload: {'answer' => 'my-secret'})
    assert_equal(envelope, vault.prepare(session_id: session_id, round_id: 'round-1', user: 'Alpha', payload: {'answer' => 'my-secret'}))
    assert_equal(older, vault.reveal(session_id: session_id, round_id: 'round-1', user: 'Alpha', commitment: older.commitment))
    assert(vault.verify(envelope), 'Envelope is not verifiable')
    vault.discard(session_id: session_id, round_id: 'round-1', user: 'Alpha')
    assert_equal(envelope, vault.reveal(session_id: session_id, round_id: 'round-1', user: 'Alpha'))
    assert_raises(T::ReadinessContract::Blocked) { vault.reveal(session_id: session_id, round_id: 'round-1', user: 'Beta') }
    assert_raises(T::ReadinessContract::Blocked) { vault.reveal(session_id: session_id + 1, round_id: 'round-1', user: 'Alpha') }
  end
  assert_equal(public_bytes, File.binread(state_path))
  assert(!public_bytes.include?('my-secret') && !public_bytes.include?(envelope.nonce), 'Secret leaked to shared execution')
  with_individual_execution(fixture, record, 'Beta') do |execution|
    assert_equal(nil, execution.private_choices.reveal(session_id: session_id, round_id: 'round-1', user: 'Beta'))
  end
  private_path = Dir.glob(File.expand_path(File.join(File.dirname(state_path), 'private-inputs', '*', 'sandbox-k02.json'))).find do |path|
    File.read(path).include?('my-secret')
  end
  private_bytes = File.binread(private_path)
  cold = File.expand_path('../support/tournament_private_choices_cold_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, cold, fixture.directory], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert(output.include?('PASS cold private choice'), output)
  assert_equal(private_bytes, File.binread(private_path))
  damaged = JSON.parse(private_bytes)
  damaged['entries'].values.first['payload']['answer'] = 'tampered'
  File.binwrite(private_path, JSON.generate(damaged))
  begin
    assert_raises(HiddenSubmissions::StorageError) do
      with_individual_execution(fixture, record, 'Alpha') do |execution|
        execution.private_choices.reveal(session_id: session_id, round_id: 'round-1', user: 'Alpha')
      end
    end
  ensure
    File.binwrite(private_path, private_bytes)
  end
  with_individual_execution(fixture, record, 'Alpha') do |execution, _authority, session|
    vault = execution.private_choices
    assert_equal(envelope, vault.reveal(session_id: session_id, round_id: 'round-1', user: 'Alpha'))
    session.choose_actor('Beta'); session.choose_actor('Alpha')
    assert_raises(T::ReadinessContract::Blocked) { vault.reveal(session_id: session_id, round_id: 'round-1', user: 'Alpha') }
  end
end
puts 'PASS local tournament private vault: own actor/session, durable envelope versions, retry reuse, no shared history secret, separate actor storage and ABA guard'
