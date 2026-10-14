require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
$stdout.sync = true
names = %w[Organizator Beta]
draw = [[0,0],[0,1],[0,2],[1,1],[1,0],[1,2],[2,1],[2,0],[2,2]]
with_fixture(game: 'tic_tac_toe', names: names, rematch: false, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  backend = fixture.backend
  records = [backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'draw-final'))]
  fixture.now = records.first['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  winner = nil
  3.times do |attempt|
    record = records.last
    intent = record['preview']['intent_id']
    with_dispatch(fixture, record, names.first) { |d| d.configure(intent_id: intent, max_tables: 2) }
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
    2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    board = dispatch_state(fixture)['executions'].values.find { |row| row['record_intent'] == intent && row['start'] }
    assert(board, 'Replay must start through normal invitations and admission')
    if attempt < 2
      finish_dispatch_board(fixture, record, board, moves: draw)
      with_individual_execution(fixture, record, names.first) do |e|
        assert_equal('tie_requires_resolution', e.progress['knockout_state'])
        assert_equal(nil, e.progress['champion'])
        preview = e.knockout_preview
        assert_equal(:confirmed, preview[:state], preview.inspect)
        assert_equal(1, preview[:plan]['round'])
        assert_equal(attempt + 1, preview[:plan]['replay']['attempt'])
        assert_equal(:confirmed, e.knockout_accept(preview: preview[:preview])[:state])
        shown = e.knockout_execution_preview
        assert_equal(:confirmed, shown[:state], shown.inspect)
        accepted = e.knockout_execution_accept(preview: shown[:preview])
        assert_equal(:confirmed, accepted[:state], accepted.inspect)
        records << accepted[:record]
      end
    else
      winner = board['request']['players'].min_by { |person| person['seat'] }['account']
      if ARGV.include?('--cold')
        people = board['request']['players'].sort_by { |person| person['seat'] }
        commands = [[0,0],[1,0],[0,1],[1,1],[0,2]].each_with_index.map do |(x,y), index|
          {'actor' => people[index % 2]['username'], 'id' => "replay-resume-#{index}", 'before_count' => index,
            'selection' => {'kind' => 'grid', 'action' => 'select', 'x' => x, 'y' => y}}
        end
        commands.first(2).each do |command|
          with_individual_execution(fixture, record, command['actor']) do |e|
            status = e.local_game(action: :local_game_status)[:status]
            result = e.local_game(action: :local_game_move, operation_id: command['id'],
              revision: status['revision'], move_selection: command['selection'])
            assert_equal(:confirmed, result[:state], result.inspect)
          end
        end
        before = dispatch_state(fixture)
        unfinished = before['executions'].values.find { |row| row['record_intent'] == intent }
        assert_equal(nil, unfinished['result'])
        assert_equal(2, before['busy'].size)
        with_individual_execution(fixture, record, names.first) do |e|
          assert_equal('awaiting_results', e.progress['knockout_state'])
          assert_equal(:blocked, e.knockout_preview[:state])
        end
        probe = File.expand_path('../support/tournament_resume_moves_probe.rb', __dir__)
        output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'tic_tac_toe', intent,
          JSON.generate(commands.drop(2))], err: [:child, :out], &:read)
        assert($?.success?, output)
        after = dispatch_state(fixture)
        completed = after['executions'].values.find { |row| row['record_intent'] == intent }
        assert_equal(unfinished['start'], completed['start'])
        assert_equal(unfinished['target'], completed['target'])
        assert_equal(unfinished['moves'], completed['moves'].first(2))
        assert_equal(before['native']['creates'], after['native']['creates'])
        assert_equal(5, completed['moves'].size)
        assert_equal(3, after['executions'].size)
        assert_equal(unfinished['epoch'], completed['result']['epoch'])
        assert_equal(unfinished['epoch'] + 1, completed['epoch'])
        names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
        assert_equal(after['executions'], dispatch_state(fixture)['executions'])
        puts 'PASS unfinished replay: fresh process restores same game, prior moves and reservations, then finishes once'
      else
        finish_dispatch_board(fixture, record, board)
      end
      with_individual_execution(fixture, record, names.first) do |e|
        assert_equal('completed', e.progress['knockout_state'])
        assert_equal(winner, e.progress['champion'])
      end
    end
    assert_equal({}, dispatch_state(fixture)['busy'])
    puts "PASS actual knockout game #{attempt + 1}"
  end
  assert_equal(3, records.map { |r| r['preview']['source']['candidate']['matches'].first['match_id'] }.uniq.size)
  executions = dispatch_state(fixture)['executions'].values
  results = records.map { |record| executions.find { |row| row['record_intent'] == record['preview']['intent_id'] }['result']['summary'] }
  assert_equal([[], [], [winner]], results.map { |result| result['winners'] })
  records.each { |record| assert_equal(record, fixture.backend(context: nil).readback(intent_id: record['preview']['intent_id'])) }
end
puts 'PASS knockout replays: two real draws, new invitations/Runner games, final winner and unchanged cold history'
