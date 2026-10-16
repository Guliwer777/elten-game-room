require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
T::LocalIndividualExecutionStorage.prepend(Module.new do
  def write(document, receipt: nil)
    value = super
    if $lost_renewal_reply && receipt.is_a?(Hash) && receipt.values.any? { |row| row.is_a?(Hash) && row.key?('replaces_id') }
      $lost_renewal_reply = false
      raise T::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'lost-renewal-reply', receipt: receipt)
    end
    value
  end
end)
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'invitation-renewal'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
  2.times { %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true); d.advance(intent_id: intent) } } }
  original = dispatch_state(fixture)['native']['cores'].fetch(0)['invitations'].fetch('beta')
  renew = {intent_id: intent, account: 'beta', invitation_id: original['id']}
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:invitation_not_expired, d.renew_invitation(**renew)[:reason]) }
  fixture.now = original['expires_at']
  %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true) } }
  with_dispatch(fixture, record, 'Beta') do |d|
    assert_raises(T::CoordinationContract::Blocked) { d.accept(intent_id: intent) }
    assert_equal(:not_coordinator, d.renew_invitation(**renew)[:reason])
  end
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:invitation_changed, d.renew_invitation(**renew.merge(invitation_id: original['id'] + 1))[:reason]) }
  $lost_renewal_reply = true
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:uncertain, d.renew_invitation(**renew)[:state]) }
  state = dispatch_state(fixture)
  replacement = state['native']['cores'].fetch(0)['invitations'].fetch('beta')
  assert(replacement['id'] != original['id'], 'Renewal must change the invitation identity')
  assert_equal(original['id'], replacement['replaces_id'])
  assert_equal(original['native_uuid'], replacement['native_uuid'])
  assert_equal(1, state['native']['creates'].size)
  assert_equal(2, state['busy'].size)
  assert_equal(1, state['native']['cores'].first['participants'].size)
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:confirmed, d.renew_invitation(**renew)[:state]) }
  assert_equal(state, dispatch_state(fixture))
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:no_expired_invitation, d.renew_expired(intent_id: intent)[:reason]) }
  fixture.now = replacement['expires_at']
  %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true) } }
  with_dispatch(fixture, record, 'Alpha') do |d|
    assert_equal(:confirmed, d.renew_expired(intent_id: intent)[:state])
    assert_equal(:invitation_changed, d.renew_invitation(**renew)[:reason])
  end
  latest = dispatch_state(fixture)['native']['cores'].first['invitations'].fetch('beta')
  assert_equal(replacement['id'], latest['replaces_id'])
  renew = renew.merge(invitation_id: replacement['id'])
  %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  with_dispatch(fixture, record, 'Alpha') do |d|
    assert_equal(:already_entered, d.renew_invitation(**renew)[:reason])
    assert_equal(:confirmed, d.advance(intent_id: intent)[:state])
    assert_equal(:already_started, d.renew_invitation(**renew)[:reason])
  end
  assert_equal(1, dispatch_state(fixture)['executions'].values.count { |row| row['start'] })
end
with_fixture(game: 'farkle', names: %w[Alpha Beta Gamma], players_per_match: 3, rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'three-seat-renewal'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
  effects = []
  %w[Alpha Beta Gamma].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true) } }
  2.times { %w[Alpha Beta Gamma].each { |name| with_dispatch(fixture, record, name) { |d| effects << [name, d.advance(intent_id: intent)] } } }
  assert_equal(1, dispatch_state(fixture)['native']['cores'].size, effects.inspect)
  original = dispatch_state(fixture)['native']['cores'].first['invitations']
  assert_equal(2, original.size)
  fixture.now = original.values.map { |row| row['expires_at'] }.max
  %w[Alpha Beta Gamma].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true) } }
  with_dispatch(fixture, record, 'Alpha') do |d|
    assert_equal(:confirmed, d.renew_expired(intent_id: intent)[:state])
    assert_equal(1, dispatch_state(fixture)['native']['cores'].first['invitations'].values.count { |row| row.key?('replaces_id') })
    assert_equal(:confirmed, d.renew_expired(intent_id: intent)[:state])
    assert_equal(:no_expired_invitation, d.renew_expired(intent_id: intent)[:reason])
  end
  state = dispatch_state(fixture)
  assert_equal(1, state['native']['creates'].size)
  assert_equal(3, state['busy'].size)
  state['native']['cores'].first['invitations'].each { |account, row| assert_equal(original[account]['id'], row['replaces_id']) }
  %w[Alpha Beta Gamma].each { |name| with_dispatch(fixture, record, name) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:confirmed, d.advance(intent_id: intent)[:state]) }
  assert_equal(1, dispatch_state(fixture)['executions'].values.count { |row| row['start'] })
end
puts 'PASS expired invitation renewal: exact predecessor, owner, expiration boundary, lost reply, no duplicate room, own admission and single Start'
