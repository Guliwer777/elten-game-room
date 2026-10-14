require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
$stdout.sync = true
# Advance the isolated test clock through the game's presentation pauses.
# Native timestamps and game clocks share Time.now; no game event is fabricated.
$quiz_finish_time = Time.now
Time.singleton_class.prepend(Module.new do
  def now; $quiz_finish_time || super; end
end)
existing = ARGV.first == '--finish-existing' && ARGV.fetch(1)
scenario = lambda do |fixture|
  record = existing ? fixture.backend.readback(intent_id: 'quiz-complete') : start_individual_match(fixture, intent_id: 'quiz-complete')
  model = fixture.registry.build('quiz')
  questions = model.send(:pack_questions, model.normalize_options({}))
  steps = 0
  pauses = 0
  finished = false
  until finished
    acted = false
    %w[Alpha Beta].each do |actor|
      with_individual_execution(fixture, record, actor) do |execution|
        status = execution.local_game(action: :local_game_status)[:status]
        if status['phase'] == 'finished'
          finished = true
          break
        end
        next if acted || status['actions'].empty?
        choice = status['actions'].first
        if status['phase'] == 'answering' && choice['kind'] == 'question'
          spec = execution.local_game(action: :local_game_surface)[:effect][:spec]
          question = questions.find { |row| row['prompt'].to_s == spec.prompt.to_s }
          assert(question, 'Displayed question must come from the installed public content')
          answer = spec.options.find do |option|
            actor == 'Alpha' ? option.label.to_s == question['correct'].to_s : option.label.to_s != question['correct'].to_s
          end
          assert(answer, 'Question must expose a legal displayed answer')
          choice = status['actions'].find { |selection| selection['answer'] == answer.id }
          assert(choice, 'Displayed answer must be a game-owned legal selection')
        end
        steps += 1
        assert(steps <= 150, 'Quiz must finish within the bounded legal scenario')
        result = execution.local_game(action: :local_game_move, operation_id: "quiz-finish-#{steps}",
          revision: status['revision'], move_selection: choice)
        assert_equal(:confirmed, result[:state], result.inspect)
        acted = true
        puts "PASS quiz question completed at action #{steps}" if choice['action'] == 'finish_question'
      end
      break if finished || acted
    end
    unless acted || finished
      pauses += 1
      assert(pauses <= 20, 'Quiz stopped without a legal action after presentation pauses')
      $quiz_finish_time += 5
    end
  end
  with_individual_execution(fixture, record, 'Beta') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
    before = JSON.parse(File.binread(path))
    prior = before['executions'].values.first
    assert_equal(15, prior['moves'].sum { |move| move['record']['packet']['data']['events'].count { |event| event['action'] == 'question_finished' } })
    core = before['native']['cores'].find { |row| row['id'] == prior['start']['native_uuid'] }
    T::LocalGameResult.with_core(core, prior, owner: core['owner']) do |_tx, _transport, _table, repository, session|
      snapshot = repository.snapshot_for(session, force_events: true)
      replay = model.replay(snapshot.session, snapshot.events, repository)
      exported = T::GameResult.from_replay(game: model, replay: replay, players: prior['request']['players'],
        options: prior['target']['native']['options'], event_count: snapshot.events.size,
        result_policy: T::GameResult::SCORE_EXPORT_POLICY)
      assert_equal({'alpha' => 15, 'beta' => 0}, exported['scores'])
    end
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(['alpha'], result[:effect]['summary']['winners'])
    expected_scores = record['evidence']['source'].key?('result_policy') ? {'alpha' => 15, 'beta' => 0} : nil
    assert_equal(expected_scores, result[:effect]['summary']['scores'])
    assert_equal(true, execution.progress['complete'])
    assert_equal([2, 0], execution.progress['standings'].map { |row| row['points'] })
    event_count = status['event_count']
    bytes = File.binread(path)
    after = JSON.parse(bytes)
    assert_equal({}, after['busy'])
    assert_equal(prior['moves'], after['executions'].values.first['moves'])
    probe = File.expand_path('../support/tournament_game_finish_probe.rb', __dir__)
    output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'quiz', 'quiz-complete', event_count.to_s, 'alpha'], err: [:child, :out], &:read)
    assert($?.success?, output)
    assert_equal(bytes, File.binread(path))
  end
end
if existing
  fixture = TournamentLocalExecutionPlanSupport::Fixture.new(existing, game: 'quiz', reopen: true)
  begin
    scenario.call(fixture)
  ensure
    fixture.close
  end
else
  with_fixture(game: 'quiz', names: %w[Alpha Beta], rematch: false, &scenario)
end
puts 'PASS complete tournament Quiz: real private answers/reveals, 15-point game result, common 2/0 standings, busy release and cold archive'
