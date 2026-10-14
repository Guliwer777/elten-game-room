require_relative '../support/tournament_dispatch'
require_relative '../../lib/tournaments/local_readiness_backend'
include TournamentDispatchSupport
with_fixture(game: 'tic_tac_toe', names: %w[Organizator Beta], rematch: true,
  group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  candidate = fixture.backend.preview(publication_ref: fixture.reference, base_seats: fixture.base,
    intent_id: 'direct-boundary')['source']['candidate']
  validator = T::LocalReadinessBackend.allocate
  validator.send(:validate_candidate!, candidate)
  %w[phase_digest publication_digest generation round].each do |key|
    bad = Marshal.load(Marshal.dump(candidate))
    bad['knockout'][key] = key == 'round' ? 1.0 : '0' * 64
    error = key == 'publication_digest' ? T::ReadinessContract::Blocked : T::Publication::Invalid
    assert_raises(error) { validator.send(:validate_candidate!, bad) }
  end
  bad = Marshal.load(Marshal.dump(candidate))
  bad['matches'].first['players'].reverse!
  assert_raises(T::ReadinessContract::Blocked) { validator.send(:validate_candidate!, bad) }
  bad = Marshal.load(Marshal.dump(candidate))
  bad['format'] = 'round_robin'
  assert_raises(T::Publication::Invalid) { validator.send(:validate_candidate!, bad) }
  bad = Marshal.load(Marshal.dump(candidate))
  bad['group_advancement'] = nil
  assert_raises(T::ReadinessContract::Blocked) { validator.send(:validate_candidate!, bad) }
end
with_fixture(game: 'tic_tac_toe', names: %w[Organizator Beta], rematch: false,
  group_count: 2, places_per_group: 1) do |fixture|
  assert_raises(T::Publication::Invalid) do
    fixture.backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'legacy-groups')
  end
end
with_fixture(game: 'three_five_eight', players_per_match: 3, names: %w[Organizator Beta],
  rematch: false, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  assert_raises(T::Publication::Invalid) do
    fixture.backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'three-player-game')
  end
end
puts 'PASS direct final boundaries: readiness source, exact metadata/ordered seats, unchanged manual groups'
