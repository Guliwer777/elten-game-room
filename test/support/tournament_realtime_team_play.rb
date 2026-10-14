require_relative 'pong_client'
require_relative 'tournament_declared_team_execution'
module TournamentRealtimeTeamPlay
  include TournamentDeclaredTeamExecutionSupport
  def play_realtime_team_match(fixture, record, match_index = 0, resume_after: nil, checkpoint: nil)
    people = record['evidence']['plan']['matches'].fetch(match_index)['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
    owner = people.first
    result = nil
    with_declared_team_execution(fixture, record, owner, match_index) do |execution|
      view = execution.local_game(action: :local_realtime_view)[:effect]
      assert_equal(4, view[:replay].players.size)
      h = bridge = nil
      open_clients = lambda do
        h = PongHarness.new(players: view[:replay].players, viewers: people, owner: owner, session: view[:session],
          session_id: view[:session]['__id'], table_id: view[:table]['__id'], initial_events: view[:replay].accepted_events)
        bridge = T::RealtimeMatchClient.new(program: h.programs[owner], request: execution.selection[:request],
          native: execution.selection[:native], registry: fixture.registry, viewer: owner, snapshot: -> { view },
          services: {clock: -> { h.now }, audio: PongTestAudio.new,
            channel_factory: ->(**args) { PongTestChannel.new(h.network, **args) }})
        h.clients[owner].close
        assert(bridge.start, 'Team client must bind the confirmed four-player Start')
        h.clients[owner] = bridge.instance_variable_get(:@client)
        bridge.attach_view(Form.new([]), h.surfaces[owner])
      end
      begin
        open_clients.call
        teams = view[:replay].state[:options]['team_seats']
        owner_team = teams[h.players.index(owner)]
        7.times do |index|
          h.advance(800)
          server = h.clients[owner].engine.server
          if teams[server] == owner_team
            people.each_with_index { |name, seat| h.surfaces[name].controls['move'] = 1 if teams[seat] != owner_team }
            h.press(people[server])
          else
            receiver = h.clients[owner].snapshot.fetch('receiver')
            assert(h.clients[people[receiver]].request_hurry, 'Actual receiver must hurry the opponent server')
          end
          1800.times do
            h.advance(1)
            break if h.clients[owner].context_data['pong_point']
          end
          input = T::RealtimePointInput.capture(bridge)
          assert(input, 'All four genuine clients must agree on the team point')
          status = execution.local_game(action: :local_game_status)[:status]
          result = execution.local_game(action: :local_game_move, operation_id: "team-point-#{index}",
            revision: status['revision'], move_selection: input.to_h['selection'], realtime_input: input)
          assert_equal(:confirmed, result[:state], result.inspect)
          assert_equal(index + 1, result[:status]['event_count'])
          view = execution.local_game(action: :local_realtime_view)[:effect]
          h.instance_variable_set(:@replay, view[:replay])
          h.clients.each { |name, client| client.before_wait(view[:replay], name) }
          people.each { |name| h.surfaces[name].controls['move'] = 0 }
          if resume_after == index + 1
            bridge.close
            h.close
            checkpoint&.call
            view = execution.local_game(action: :local_realtime_view)[:effect]
            open_clients.call
            assert_equal(index + 1, view[:replay].accepted_events.size)
          end
        end
        status = execution.local_game(action: :local_game_status)[:status]
        assert(status['finished'], 'Actual doubles must finish before finalization')
        result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
        assert_equal(:confirmed, result[:state], result.inspect)
        assert_equal([7, 0], result[:effect]['summary']['scores'].values.sort.reverse)
      ensure
        bridge&.close
        h&.close
      end
    end
      result
  end
end
