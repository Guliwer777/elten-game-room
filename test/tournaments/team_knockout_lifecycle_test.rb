require_relative '../support/tournament_team_dispatch'
include TournamentTeamDispatchSupport
$stdout.sync = true
names = %w[Ala Anna Bartek Beata Celina Cezary Daria Daniel]
context, service, reference = fixture(names: names, rematch: false,
  group_advancement: T::GroupAdvancement::AUTOMATIC, game_options: {'score_limit' => 1})
records = []
with_backend(context) do |backend|
  shown = backend.preview_pairs(publication_ref: reference, pairs: names.each_slice(2).to_a,
    team_template: TEMPLATE, intent_id: 'team-knockout-groups')
  records << backend.accept(preview: shown)
end
context.now = records.first['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
3.times do |round|
  record = records.last
  intent = record['preview']['intent_id']
  actors = record['evidence']['source']['roster'].map { |person| person['username'] }
  with_team_dispatch(context, 'Organizator') { |dispatcher| dispatcher.configure(intent_id: intent, max_tables: 2) }
  actors.each { |actor| with_team_dispatch(context, actor) { |dispatcher| dispatcher.available(intent_id: intent, available: true) } }
  2.times { actors.each { |actor| with_team_dispatch(context, actor) { |dispatcher| dispatcher.advance(intent_id: intent) } } }
  actors.each { |actor| with_team_dispatch(context, actor) { |dispatcher| assert_equal(:confirmed, dispatcher.accept(intent_id: intent)[:state]) } }
  actors.each { |actor| with_team_dispatch(context, actor) { |dispatcher| dispatcher.advance(intent_id: intent) } }
  boards = team_dispatch_state(context)['executions'].values.select { |row| row['record_intent'] == intent && row['start'] }
  assert_equal(round == 2 ? 1 : 2, boards.size)
  boards.each { |row| finish_team_dispatch_board(context, record, row) }
  assert_equal({}, team_dispatch_state(context)['busy'])
  if round == 2
    with_team_match(context, record, actors.first) do |execution|
      progress = execution.progress
      assert_equal('completed', progress['knockout_state'])
      assert_equal(progress['qualified'].first, progress['champion'])
    end
  else
    with_team_match(context, record, 'Organizator') do |execution|
      preview = execution.knockout_preview
      assert_equal(:confirmed, preview[:state], preview.inspect)
      assert_equal(:confirmed, execution.knockout_accept(preview: preview[:preview])[:state])
    end
    with_backend(context) do |backend|
      records << backend.accept(preview: backend.knockout_execution_preview(parent_intent: intent))
    end
  end
  puts "PASS played team tournament stage #{round + 1}"
end
with_backend(context) do |backend|
  records.each { |record| assert_equal(record, backend.readback(intent_id: record['preview']['intent_id'])) }
end
assert_equal(5, team_dispatch_state(context)['executions'].values.count { |row| row['result'] })
puts 'PASS full team knockout: actual groups, semifinals, final, champion, busy release and immutable cold ancestors'
