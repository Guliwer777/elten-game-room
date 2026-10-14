require_relative 'tournament_declared_team_execution'
module TournamentGenericTeamRoundSupport
  include TournamentDeclaredTeamExecutionSupport

  def generic_team_state(fixture)
    JSON.parse(File.binread(generic_team_state_path(fixture)))
  end

  def generic_team_state_path(fixture)
    File.join(fixture.directory, 'team-plans/fixed-teams-v1/execution-ft2-v1/state.json')
  end

  def start_generic_team_round(fixture, record)
    intent = record['preview']['intent_id']
    matches = record['evidence']['plan']['matches']
    actors = matches.flat_map { |match| match['players'].map { |person| person['username'] } }.uniq
    with_declared_team_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: matches.size) }
    actors.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
    2.times { actors.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    rows = generic_team_state(fixture)['executions'].values.select { |row| row['record_intent'] == intent }
    assert_equal(matches.size, rows.size)
    assert(rows.all? { |row| row['start'].nil? }, 'Invitations alone must not start any match')
    actors.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    actors.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    rows = generic_team_state(fixture)['executions'].values.select { |row| row['record_intent'] == intent }
    assert_equal(matches.size, rows.count { |row| row['start'] })
    assert_equal(actors.size, generic_team_state(fixture)['busy'].size)
  end

  def finish_generic_team_taboo(fixture, record, match_index, pause_after: nil)
    match = record['evidence']['plan']['matches'].fetch(match_index)
    model = fixture.registry.build(match['game_id'])
    people = match['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
    finished = false
    summary = nil
    40.times do |number|
      document = generic_team_state(fixture)
      row = document['executions'].values.find { |item| item['record_intent'] == record['preview']['intent_id'] && item['request']['match_id'] == match['match_id'] }
      core = document['native']['cores'].find { |item| item['id'] == row['start']['native_uuid'] }
      coordinator = people.find { |person| person.downcase == row['coordinator'] }
      replay = nil
      T::LocalGameResult.with_core(core, row, owner: coordinator) do |_tx, _transport, _table, repository, session|
        snapshot = repository.snapshot_for(session, force_events: true)
        replay = model.replay(snapshot.session, snapshot.events, repository)
      end
      if replay.finished?
        with_declared_team_execution(fixture, record, coordinator, match_index) do |execution|
          status = execution.local_game(action: :local_game_status)[:status]
          result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
          assert_equal(:confirmed, result[:state], result.inspect)
          summary = result[:effect]['summary']
          assert_equal([0, people.size / 2], summary['scores'].values.sort)
        end
        finished = true
        break
      end
      state, actor = replay.state, people.first
      action = case state[:phase]
      when :awaiting_deal then 'deal'
      when :ready then actor = state[:current_player]; 'start'
      when :preparing then $generic_round_time += 4; 'begin'
      when :describing
        if state[:team].zero? && state[:review].empty?
          actor = state[:current_player]; 'correct'
        else
          $generic_round_time += 31; 'timeout'
        end
      when :review then 'approve'
      else raise "Unexpected actual Taboo phase #{state[:phase]}"
      end
      with_declared_team_execution(fixture, record, actor, match_index) do |execution|
        status = execution.local_game(action: :local_game_status)[:status]
        result = execution.local_game(action: :local_game_move, operation_id: "#{match['match_id']}-real-#{Array(row['moves']).size}",
          revision: status['revision'], move_selection: {'action' => action, 'token' => model.token(state)})
        assert_equal(:confirmed, result[:state], result.inspect)
      end
      return :paused if pause_after && Array(row['moves']).size + 1 >= pause_after
    end
    assert(finished, 'The actual Taboo match must finish within the bounded scenario')
    summary
  end

  def finish_generic_team_domino(fixture, record)
    match = record['evidence']['plan']['matches'].first
    people = match['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
    150.times do |number|
      row = generic_team_state(fixture)['executions'].values.find { |item| item['record_intent'] == record['preview']['intent_id'] }
      coordinator = people.find { |person| person.downcase == row['coordinator'] }
      view = nil
      with_declared_team_execution(fixture, record, coordinator) { |e| view = e.local_game(action: :local_game_status)[:status] }
      if view['finished']
        result = nil
        with_declared_team_execution(fixture, record, coordinator) do |execution|
          result = execution.local_game(action: :finalize_local_game, revision: view['revision'])
          assert_equal(:confirmed, result[:state])
        end
        return result[:effect]['summary']
      end
      acted = false
      [view['current_player'], *people].compact.uniq.each do |actor|
        with_declared_team_execution(fixture, record, actor) do |execution|
          status = execution.local_game(action: :local_game_status)[:status]
          choice = status['actions'].first
          next unless choice
          result = execution.local_game(action: :local_game_move, operation_id: "#{match['match_id']}-replay-real-#{number}",
            revision: status['revision'], move_selection: choice)
          assert_equal(:confirmed, result[:state], result.inspect)
          acted = true
        end
        break if acted
      end
      assert(acted, 'A game-owned Domino action is required')
    end
    raise 'The real Domino game did not finish within the bounded scenario'
  end
end
