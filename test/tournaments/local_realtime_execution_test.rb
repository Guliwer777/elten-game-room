require_relative '../support/pong_client'
require_relative '../support/tournament_individual_execution'
require_relative '../../lib/tournaments/local_realtime_individual_execution'
require 'open3'
require 'rbconfig'
include TournamentIndividualExecutionSupport
T::LocalIndividualExecutionStorage.prepend(Module.new do
  def write(document, receipt: nil)
    value = super
    if $realtime_lost_reply && receipt.is_a?(Hash) && receipt.key?('realtime_input')
      $realtime_lost_reply = false
      raise T::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'realtime-lost-reply', receipt: receipt)
    end
    value
  end
end)
with_fixture(game: 'axel_pong', names: %w[Alice Bob], rematch: false, game_options: {'target' => 7}) do |fixture|
  klass = T::LocalRealtimeIndividualExecution
  record = start_individual_match(fixture, intent_id: 'local-realtime-game', execution_class: klass)
  owner = record['evidence']['plan']['matches'].first['players'].first['username']
  with_individual_execution(fixture, record, owner, execution_class: klass) do |execution|
    view = execution.local_game(action: :local_realtime_view)[:effect]
    changes = T::LocalGameEvents::Pending.new
    subscription = T::LocalGameEvents.subscribe(view.fetch(:change_identity), changes)
    h = PongHarness.new(players: view[:replay].players, owner: owner, session: view[:session],
      session_id: view[:session]['__id'], table_id: view[:table]['__id'])
    bridge = T::RealtimeMatchClient.new(program: h.programs[owner], request: execution.selection[:request],
      native: execution.selection[:native], registry: fixture.registry, viewer: owner, snapshot: -> { view },
      services: {clock: -> { h.now }, audio: PongTestAudio.new,
        channel_factory: ->(**args) { PongTestChannel.new(h.network, **args) }})
    begin
      h.clients[owner].close
      assert(bridge.start, 'Client must bind to the actual confirmed local Start')
      h.clients[owner] = bridge.instance_variable_get(:@client)
      bridge.attach_view(Form.new([]), h.surfaces[owner])
      h.advance(220)
      7.times do |index|
        h.advance(380) unless index.zero?
        other = h.players.find { |person| person != owner }
        if h.players[h.clients[owner].engine.server] == owner
          h.surfaces[other].controls['move'] = 1
          h.press(owner)
        else
          assert(h.clients[owner].request_hurry, 'The actual opponent server must be hurriable')
        end
        1600.times do
          h.advance(1)
          break if h.clients[owner].context_data['pong_point']
        end
        token = T::RealtimePointInput.capture(bridge)
        assert(token, 'A real client agreed goal is required')
        if index.zero?
          original = token.to_h
          T::RealtimePointInput::FIELDS.each do |field|
            forged = T::Publication::Data.copy(original)
            forged[field] = nil
            rejected = false
            begin
              T::RealtimePointInput.validate!(forged, request: execution.selection[:request].to_h,
                native_uuid: original['native_uuid'], table_id: original['table_id'], session_id: original['session_id'],
                control_epoch: original['control_epoch'], selection: original['selection'], game: fixture.registry.build('axel_pong'))
            rescue T::CoordinationContract::Blocked
              rejected = true
            end
            assert(rejected, "Tampered realtime #{field} must be rejected")
          end
        end
        status = execution.local_game(action: :local_game_status)[:status]
        arguments = {action: :local_game_move, operation_id: "realtime-point-#{index}",
          revision: status['revision'], move_selection: token.to_h['selection']}
        refused = execution.local_game(**arguments)
        assert_equal(:blocked, refused[:state])
        assert_equal(:invalid_action, refused[:reason])
        $realtime_lost_reply = index.zero?
        result = execution.local_game(**arguments, realtime_input: token)
        if index.zero?
          assert(!$realtime_lost_reply, 'Lost reply injection must follow an actual persisted point')
          assert_equal(:uncertain, result[:state], result.inspect)
          result = execution.local_game(action: :local_move_status, operation_id: arguments[:operation_id])
        end
        assert_equal(:confirmed, result[:state], result.inspect)
        assert_equal(index + 1, result[:status]['event_count'])
        assert(changes.take, 'Actual committed goal must notify other local readers')
        assert_equal(token.to_h, result[:effect]['realtime_input'])
        again = execution.local_game(**arguments, realtime_input: token)
        assert_equal(result[:effect], again[:effect])
        assert(!changes.take, 'An idempotent readback must not emit a new commit')
        view = execution.local_game(action: :local_realtime_view)[:effect]
        h.instance_variable_set(:@replay, view[:replay])
        h.clients.each { |name, client| client.before_wait(view[:replay], name) }
        h.surfaces[other].controls['move'] = 0
      end
      status = execution.local_game(action: :local_game_status)[:status]
      assert(status['finished'], 'Actual game must finish before finalization')
      output, error, guard_status = Open3.capture3(RbConfig.ruby,
        File.expand_path('../support/tournament_realtime_guard_probe.rb', __dir__), fixture.directory)
      assert(guard_status.success?, "Blocked realtime result view failed: #{output}\n#{error}")
      puts output
      result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
      assert_equal(:confirmed, result[:state], result.inspect)
      assert_equal({owner.downcase => 7, h.players.find { |name| name != owner }.downcase => 0}, result[:effect]['summary']['scores'])
      assert_equal([2, 0], result[:status]['standings'].map { |row| row['points'] }.sort.reverse)
    ensure
      subscription.close
      changes.close
      bridge.close
      h.close
    end
  end
  with_individual_execution(fixture, record, owner, execution_class: klass) do |cold|
    status = cold.local_game(action: :local_game_status)[:status]
    assert(status['finished'], 'Reopened execution must verify real persisted point contexts')
    assert_equal(7, status['event_count'])
  end
  document = JSON.parse(File.binread(File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')))
  assert_equal({}, document['busy'])
  output, error, process = Open3.capture3(RbConfig.ruby, File.expand_path('../support/tournament_realtime_probe.rb', __dir__), fixture.directory)
  assert(process.success?, "Independent realtime archive failed: #{output}\n#{error}")
  puts output
end
puts 'PASS local realtime tournament execution: real consent/entry/Start, seven client-agreed points through ordinary Runner, typed context receipts, idempotent readback, result 2/0, busy release and reopened validation'
