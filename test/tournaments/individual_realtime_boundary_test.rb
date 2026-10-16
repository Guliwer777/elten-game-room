require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
catalog = GameRoomGames::CATALOG
assert_equal(:turn_based, catalog.tournament_capabilities('scrabble')[:execution])
assert(catalog.build('scrabble').background_client?, 'A background preview is not realtime physics')
future = Class.new(GameRoomGames::TicTacToe) do
  def id; 'future_realtime_client'; end
  def tournament_execution_kind; :realtime; end
end
[['axel_pong', catalog], ['audio_ball', catalog], ['future_realtime_client', GameRoomGames::Registry.new([future])]].each do |id, registry|
  game = registry.build(id)
  assert(game.session_runner?, 'The point/event runner can coexist with a realtime client')
  assert_equal(:realtime, registry.tournament_capabilities(id)[:execution])
  with_fixture(game: id, registry: registry, names: %w[Alpha Beta], rematch: false) do |fixture|
    backend = fixture.backend
    record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
      base_seats: fixture.base, intent_id: 'realtime-boundary'))
    error = assert_raises(T::Publication::Invalid) do
      with_individual_execution(fixture, record, 'Alpha') { raise 'Started realtime in a turn-based executor' }
    end
    assert_equal(:realtime_execution_required, error.code)
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: 'realtime-boundary'))
    path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
    assert(!File.exist?(path), 'Rejected selection must not create readiness, invitations or a native game')
  end
end
puts 'PASS actual Pong/Audio Ball realtime boundary, future declared client without allowlist, Scrabble preview remains turn-based, no execution side effects and readable plans'
