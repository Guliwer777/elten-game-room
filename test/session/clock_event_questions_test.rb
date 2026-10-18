require_relative '../support/ui'
require_relative '../../lib/game_surfaces'
require_relative '../support/clock_event_contract'
require_relative '../../lib/game_content'
require_relative '../../content/languages'
require_relative '../../content/quiz_pl_wikidata'
require_relative '../../games/quiz_party'
require_relative '../../games/categories'

def assert_question_clock(fixture, deadline, logical_now, stage)
  snapshots = fixture.h.users.map { |user| fixture.snapshot(user) }
  assert(snapshots.map(&:events).uniq.length == 1, "#{fixture.game.id}: #{stage}: clients disagree about event offsets")
  fixture.h.users.each do |user|
    replay = fixture.replay(user)
    assert(replay.state[:deadline] == deadline, "#{fixture.game.id}: #{stage}: #{user}'s historical deadline moved to #{replay.state[:deadline]}")
    assert(fixture.logical_now(user) == logical_now, "#{fixture.game.id}: #{stage}: #{user}'s clock moved")
    assert(replay.accepted_events.length == snapshots.first.events.length, "#{fixture.game.id}: #{stage}: an accepted action disappeared")
  end
end

[GameRoomGames::QuizParty.new, GameRoomGames::Categories.new].each do |game|
  ClockEventContract.with_server_time do |time|
    quiz = game.is_a?(GameRoomGames::QuizParty)
    options = quiz ? {'answer_time' => 5} : {
      'category_set' => 'custom', 'custom_categories' => %w[country city],
      'round_category_count' => 2, 'round_time' => 10, 'target_score' => 100}
    f = ClockEventContract::Fixture.new(game, options: options)
    f.submit('Alice')
    if quiz
      r = f.replay
      f.submit('Alice', {'kind' => 'question', 'action' => 'submit',
        'question_id' => game.send(:category_surface_id, r.state), 'answer' => r.state[:choices].first})
      f.submit('Alice')
    end
    initial_deadline = 1000 + (quiz ? 5 : 10)
    assert_question_clock(f, initial_deadline, 1000, 'before freeze')
    first_events = f.snapshot.events
    time.call(1002)
    f.freeze('Alice', true)
    time.call(1050)
    assert_question_clock(f, initial_deadline, 1002, 'inside first freeze')
    time.call(1062)
    f.freeze('Alice', false)
    assert_question_clock(f, initial_deadline, 1002, 'after first thaw')
    time.call(1063)
    f.freeze('Alice', true)
    f.h.as('Alice') { f.h.transports.fetch('Alice').transfer_room_owner(f.h.table, 'Bob') }
    f.h.as('Bob') { f.h.transports.fetch('Bob').room_snapshot(f.h.table) }
    time.call(1100)
    assert_question_clock(f, initial_deadline, 1003, 'new owner during second freeze')
    time.call(1123)
    f.freeze('Bob', false)
    assert_question_clock(f, initial_deadline, 1003, 'new owner after second thaw')
    assert(f.snapshot.events == first_events, "#{game.id}: thaw rewrote historical actions")

    if quiz
      f.h.users.each do |user|
        state = f.replay(user).state
        f.submit(user, {'kind' => 'question', 'action' => 'submit',
          'question_id' => game.send(:question_surface_id, state),
          'answer' => game.send(:correct_option_index, state).to_s})
      end
      f.submit('Bob', nil, control: true)
      f.h.users.each { |user| f.submit(user) }
      f.submit('Bob', nil, control: true)
      finished = f.replay('Bob')
      assert(finished.state[:phase] == :starting, 'Quiz did not finish the resumed question')
      finished_logical = 1003
      pause = game.class::NEXT_QUESTION_PAUSE
    else
      # No private submissions: the successor closes the expired answer window,
      # reviews the empty sheet and commits a real native round-finish event.
      time.call(initial_deadline + game.class::DEADLINE_SUBMISSION_GRACE + 120)
      f.submit('Bob', nil, control: true)
      f.submit('Bob', nil, control: true)
      assert(f.replay.state[:phase] == :review, 'Categories missed the empty-answer review')
      f.submit('Alice', {'kind' => 'review', 'action' => 'finish', 'decisions' => {}})
      f.submit('Bob', nil, control: true)
      finished = f.replay('Bob')
      assert(finished.state[:phase] == :round_complete, 'Categories did not finish the resumed round')
      finished_logical = initial_deadline + game.class::DEADLINE_SUBMISSION_GRACE
      pause = game.class::NEXT_ROUND_PAUSE
    end
    assert(finished.state[:resume_at] == finished_logical + pause,
      "#{game.id}: committed presentation pause translated with an old or doubled offset")
    final_event = f.snapshot.events.last
    assert(final_event['__clock_offset'] == 120 && final_event['created_at'] == finished_logical + 120,
      "#{game.id}: finishing event lost its accepted offset")

    # Pausing again while the result is displayed must not alter its existing
    # resume boundary. The following question receives its full duration.
    f.freeze('Bob', true)
    time.call(finished_logical + 180)
    f.freeze('Bob', false)
    assert(f.replay('Bob').state[:resume_at] == finished_logical + pause,
      "#{game.id}: a later pause rewrote the completed result's resume time")
    time.call(finished_logical + pause - 1 + 180)
    assert(!game.automatic_action_due?(f.replay('Bob'), 'Alice', context: f.context('Bob')),
      "#{game.id}: result pause ended too early")
    time.call(finished_logical + pause + 180)
    f.submit('Bob', nil, control: true)
    next_deadline = finished_logical + pause + (quiz ? 5 : 10)
    assert_question_clock(f, next_deadline, finished_logical + pause, 'new question after three pauses')
    assert(f.snapshot.events.last['__clock_offset'] == 180, "#{game.id}: new question used historical rather than current offset")
    assert(f.snapshot.events.first(first_events.length) == first_events, "#{game.id}: later question altered initial history")
  end
end

puts 'PASS event clocks: Quiz/Categories native deadlines before/during/after three pauses, accepted history and other clients, host handover, result pause and full later-question duration'
