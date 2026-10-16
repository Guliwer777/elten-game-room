require_relative '../support/pong_client'
require_relative '../support/tournament_individual_execution'
require_relative '../../lib/tournaments/realtime_match_client'
include TournamentIndividualExecutionSupport

# Real accepted plan plus authenticated isolated client snapshots. This does
# not grant tournament admission/Start or exercise its point-write boundary.
with_fixture(game: 'axel_pong', names: %w[Alice Bob], rematch: false,
  game_options: {'target' => 7}) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'realtime-client-binding'))
  match = record['evidence']['plan']['matches'].first
  selectors = {evidence: record['evidence'], expected_source: record['expected_source'],
    match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'], registry: fixture.registry}
  request = T::CoordinationRequest.from_execution_plan(**selectors)
  native = T::IndividualNativePayload.from_execution_plan(**selectors)
  h = PongHarness.new(players: native.to_h['players'], options: native.to_h['options'])
  session_extra = {'__id' => 300, 'game' => 'axel_pong', '__table_owner' => 'Alice'}
  table = {'__id' => 20, '__live_session_id' => 'isolated-pong-native', 'owner' => 'Alice',
    'game' => 'axel_pong', 'game_options' => JSON.generate(native.to_h['options'])}
  snapshot = -> { {table: table, session: h.session.merge(session_extra), replay: h.replay} }
  options = {program: h.programs['Alice'], request: request, native: native, registry: fixture.registry,
    viewer: 'Alice', snapshot: snapshot,
    services: {clock: -> { h.now }, audio: PongTestAudio.new,
      channel_factory: ->(**args) { PongTestChannel.new(h.network, **args) }}}
  base_snapshot = snapshot.call
  mutations = [
    ->(value) { value[:table]['__id'] = 0 },
    ->(value) { value[:table]['__live_session_id'] = '' },
    ->(value) { value[:table]['owner'] = 'Organizator' },
    ->(value) { value[:session]['__table_owner'] = 'Bob' },
    ->(value) { value[:session]['__players'] = native.to_h['players'].reverse },
    ->(value) { value[:session]['options'] = '{broken' },
    ->(value) { value[:table]['game_options'] = JSON.generate(native.to_h['options'].merge('target' => 21)) },
    ->(value) { value[:session]['__control_ready'] = false },
    ->(value) { value[:session]['__controllers'] = {'Alice' => 'bot'} },
    ->(value) { value[:session]['game'] = 'audio_ball' }
  ]
  mutations.each do |mutate|
    changed = base_snapshot.merge(table: T::Publication::Data.copy(base_snapshot[:table]),
      session: T::Publication::Data.copy(base_snapshot[:session]))
    mutate.call(changed)
    builds = 0
    services = options[:services].merge(channel_factory: ->(**_args) { builds += 1; raise 'Invalid snapshot opened a channel' })
    invalid = T::RealtimeMatchClient.new(**options.merge(snapshot: -> { changed }, services: services))
    failure = assert_raises(StandardError) { invalid.start }
    assert(failure.is_a?(T::Publication::Invalid) || failure.is_a?(JSON::ParserError), "Invalid native context must be refused: #{failure.class}: #{failure.message}")
    assert_equal(0, builds)
    invalid.close
  end
  outside = assert_raises(T::Publication::Invalid) { T::RealtimeMatchClient.new(**options.merge(viewer: 'Organizator')) }
  assert_equal(:not_participant, outside.code)
  h.clients['Alice'].close
  bridge = T::RealtimeMatchClient.new(**options)
  begin
    assert(bridge.start, 'Bound actual client must start')
    h.clients['Alice'] = bridge.instance_variable_get(:@client)
    bridge.attach_view(Form.new([]), h.surfaces['Alice'])
    h.advance(220)
    assert_equal(nil, bridge.agreed_input)
    server = h.players[h.clients['Alice'].engine.server]
    receiver = h.players[1 - h.clients['Alice'].engine.server]
    h.surfaces[receiver].controls['move'] = 1
    h.press(server)
    1600.times do
      h.advance(1)
      break if h.clients['Alice'].context_data['pong_point']
    end
    input = bridge.agreed_input
    assert(input && input.frozen?, 'Only the actual client agreed point may be exported')
    assert_equal(request.digest, input['request_digest'])
    assert_equal(300, input['session_id'])
    assert_equal(20, input['table_id'])
    assert_equal(h.clients['Alice'].context_data, input['local_data'])
    assert_equal('pong_point', input['selection']['action'])
    assert(input['local_data'].frozen?, 'Input must be detached and immutable')
    error = Thread.new do
      begin
        bridge.agreed_input
      rescue T::Publication::Invalid => failure
        failure.code
      end
    end.value
    assert_equal(:invalid_composition, error)
    assert_equal(input, bridge.agreed_input)
    session_extra['__id'] = 301
    error = assert_raises(T::Publication::Invalid) { bridge.agreed_input }
    assert_equal(:native_target_mismatch, error.code)
    assert(!h.network['alice'].connected?, 'A changed game must close the old channel')
    assert_raises(T::Publication::Invalid) { bridge.start }
  ensure
    bridge.close
    h.close
  end
  mutable_id = String.new('isolated-new-channel')
  other_table = table.merge('__live_session_id' => mutable_id)
  other_snapshot = -> { {table: other_table, session: h.session.merge(session_extra), replay: h.replay} }
  other_bridge = T::RealtimeMatchClient.new(**options.merge(snapshot: other_snapshot))
  begin
    assert(other_bridge.start, 'A new explicit composition may bind its own current session')
    mutable_id.replace('changed-in-place')
    failure = assert_raises(T::Publication::Invalid) { other_bridge.refresh }
    assert_equal(:native_target_mismatch, failure.code)
    assert(!h.network['alice'].connected?, 'Mutating snapshot strings must not change the captured binding')
  ensure
    other_bridge.close
  end
  assert_equal(record, fixture.backend(context: nil).readback(intent_id: 'realtime-client-binding'))
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  assert(!File.exist?(path), 'Client binding must not grant tournament entry, Start or writes')
end
puts 'PASS accepted realtime match/client binding, actual agreed input, immutable scope, outside actor and wrong UI thread refusal, stale session closes channel; no execution authority'
