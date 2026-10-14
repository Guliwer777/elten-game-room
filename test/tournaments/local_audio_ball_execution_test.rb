require_relative '../support/audio_ball_client'
require_relative '../support/tournament_individual_execution'
require_relative '../../lib/tournaments/local_realtime_individual_execution'
require 'open3'
require 'rbconfig'
include TournamentIndividualExecutionSupport
with_fixture(game: 'audio_ball', names: %w[Alice Bob], rematch: false) do |fixture|
  klass = T::LocalRealtimeIndividualExecution
  record = start_individual_match(fixture, intent_id: 'local-audio-ball-game', execution_class: klass)
  owner = record['evidence']['plan']['matches'].first['players'].first['username']
  with_individual_execution(fixture, record, owner, execution_class: klass) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('audio_ball_start', status['actions'].first['action'])
    initial = execution.local_game(action: :local_game_move, operation_id: 'audio-ball-start',
      revision: status['revision'], move_selection: status['actions'].first)
    assert_equal(:confirmed, initial[:state])
    view = execution.local_game(action: :local_realtime_view)[:effect]
    h = AudioBallHarness.new(players: view[:replay].players, owner: owner, session: view[:session],
      session_id: view[:session]['__id'], table_id: view[:table]['__id'], started: false,
      initial_events: view[:replay].accepted_events)
    bridge = T::RealtimeMatchClient.new(program: Program.new, request: execution.selection[:request],
      native: execution.selection[:native], registry: fixture.registry, viewer: owner, snapshot: -> { view },
      services: {clock: -> { h.now }, audio: AudioBallTestAudio.new,
        channel_factory: ->(**args) { AudioBallTestChannel.new(h.network, **args) }})
    begin
      h.clients[owner].close
      assert(bridge.start, 'Audio Ball must bind its actual tournament Start')
      h.clients[owner] = bridge.instance_variable_get(:@client)
      bridge.attach_view(h.forms[owner], h.surfaces[owner])
      h.advance(12)
      7.times do |index|
        h.win_point(owner, persist: false)
        input = T::RealtimePointInput.capture(bridge)
        assert(input, 'An actual acknowledged Audio Ball goal is required')
        status = execution.local_game(action: :local_game_status)[:status]
        result = execution.local_game(action: :local_game_move, operation_id: "audio-point-#{index}",
          revision: status['revision'], move_selection: input.to_h['selection'], realtime_input: input)
        assert_equal(:confirmed, result[:state], result.inspect)
        assert_equal(index + 2, result[:status]['event_count'])
        view = execution.local_game(action: :local_realtime_view)[:effect]
        h.instance_variable_set(:@replay, view[:replay])
        h.events.replace(view[:replay].accepted_events)
        h.clients.each { |name, client| client.before_wait(view[:replay], name) }
        h.advance_for(5.8) unless view[:replay].finished?
      end
      status = execution.local_game(action: :local_game_status)[:status]
      assert(status['finished'], 'Actual Audio Ball must finish')
      result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
      assert_equal(:confirmed, result[:state])
      assert_equal([2, 0], result[:status]['standings'].map { |row| row['points'] }.sort.reverse)
    ensure
      bridge.close
      h.close
    end
  end
  with_individual_execution(fixture, record, owner, execution_class: klass) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert(status['finished'], 'Reopened history must verify initial randomness and every agreed goal')
    assert_equal(8, status['event_count'])
  end
  document = JSON.parse(File.binread(File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')))
  assert_equal({}, document['busy'])
  output, error, process = Open3.capture3(RbConfig.ruby, File.expand_path('../support/tournament_realtime_probe.rb', __dir__),
    fixture.directory, 'audio_ball', 'local-audio-ball-game', '8')
  assert(process.success?, "Independent Audio Ball archive failed: #{output}\n#{error}")
  puts output
end
puts 'PASS local Audio Ball: consent/entry/Start, normal randomized first server, seven genuine agreed goals through ordinary Runner, v4 small points, 2/0, reopened receipt validation and busy release'
