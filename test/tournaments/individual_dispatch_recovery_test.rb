require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
T::LocalIndividualExecutionStorage.prepend(Module.new do
  def write(document, receipt: nil)
    value = super
    if $dispatch_lost_invitation_reply && receipt.is_a?(Hash) && receipt.values.any? { |row| row.is_a?(Hash) && row.key?('recipient') }
      $dispatch_lost_invitation_reply = false
      raise T::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'lost-invitation-reply', receipt: receipt)
    end
    value
  end
end)
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: true) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'dispatch-recovery'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
  %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true); d.advance(intent_id: intent) } }
  $dispatch_lost_invitation_reply = true
  with_dispatch(fixture, record, 'Alpha') do |d|
    effect = d.advance(intent_id: intent)
    assert_equal(:uncertain, effect[:state], effect.inspect)
  end
  state = dispatch_state(fixture)
  invitation = state['native']['cores'].first['invitations'].values.first
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:invited, d.advance(intent_id: intent)[:state]) }
  assert_equal(invitation, dispatch_state(fixture)['native']['cores'].first['invitations'].values.first)
  assert_equal(1, dispatch_state(fixture)['native']['creates'].size)
  %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:confirmed, d.advance(intent_id: intent)[:state]) }
  row = dispatch_state(fixture)['executions'].values.find { |value| value['start'] }
  finish_dispatch_board(fixture, record, row)
  with_dispatch(fixture, record, 'Alpha') do |d|
    assert_equal([2], d.snapshot(intent_id: intent)['candidates'].map { |value| value['leg'] })
  end
  2.times { %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } } }
  assert_equal(2, dispatch_state(fixture)['native']['creates'].size)
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  bytes = File.binread(path)
  document = JSON.parse(bytes)
  document['native']['cores'].last['invitations'].values.first['recipient'] = 'Stranger'
  File.binwrite(path, JSON.generate(document))
  begin
    assert_raises(T::Publication::Invalid) { with_dispatch(fixture, record, 'Alpha') { |d| d.snapshot(intent_id: intent) } }
  ensure
    File.binwrite(path, bytes)
  end
end
puts 'PASS tournament dispatch recovery: lost invitation reply, no duplicate effect, actual result unlocks rematch and forged recipient rejected'
