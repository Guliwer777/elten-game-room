require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
$stdout.sync = true
names = ARGV.include?('--three') ? %w[Alpha Beta Gamma] : %w[Alpha Beta]
score = (names.size - 1) * 10
winning = ARGV.include?('--winner')
scores = names.to_h { |name| [name.downcase, winning && name != 'Alpha' ? score / 2 : score] }
with_fixture(game: 'categories', names: names, players_per_match: names.size, rematch: false,
  game_options: {'target_score' => 10, 'round_category_count' => 5,
    'round_time' => 0, 'tie_mode' => 'shared'}) do |fixture|
  if ARGV.include?('--automatic')
    backend = fixture.backend
    record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
      base_seats: fixture.base, intent_id: 'categories-complete'))
    intent = record['preview']['intent_id']
    fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
    with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
    2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    before = dispatch_state(fixture)
    assert_equal(1, before['native']['cores'].size)
    assert_equal(names.size - 1, before['native']['cores'].first['invitations'].size)
    assert_equal(1, before['native']['cores'].first['participants'].size)
    assert_equal(0, before['executions'].values.count { |row| row['start'] })
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    after = dispatch_state(fixture)
    assert_equal(1, after['native']['creates'].size)
    assert_equal(names.size, after['native']['cores'].first['participants'].size)
    assert_equal(1, after['executions'].values.count { |row| row['start'] })
    owner = after['executions'].values.first['coordinator']
  else
    record = start_individual_match(fixture, intent_id: 'categories-complete')
    owner = record['evidence']['plan']['matches'].first['players'].min_by { |person| person['seat'] }['username']
  end
  steps = 0
  finished = false
  until finished
    acted = false
    names.each do |actor|
      with_individual_execution(fixture, record, actor) do |execution|
        status = execution.local_game(action: :local_game_status)[:status]
        if status['phase'] == 'finished'
          finished = true
          next
        end
        spec = execution.local_game(action: :local_game_surface)[:effect][:spec]
        parts = spec.respond_to?(:parts) ? spec.parts.map(&:surface) : [spec]
        sheet = parts.find { |part| part.respond_to?(:fields) }
        review = parts.find { |part| part.respond_to?(:items) && part.respond_to?(:decisions) }
        choice = if status['actions'].any?
          status['actions'].first
        elsif sheet
          # Test judge assessments exercise the scoring protocol, not a dictionary.
          {'kind' => 'answer_sheet', 'action' => 'submit',
            'answers' => sheet.fields.to_h { |field| [field.id, "Test #{actor} #{field.id}"] }}
        elsif review && review.items.any? { |item| item.decision.nil? }
          {'kind' => 'review', 'action' => 'finish',
            'decisions' => review.items.to_h { |item| [item.id,
              winning && !item.answer.include?('Alpha') ? 'partial' : 'unique'] }}
        else
          status['actions'].first
        end
        next unless choice
        steps += 1
        assert(steps <= 60, 'Rotating judge rounds must finish within the bounded scenario')
        result = execution.local_game(action: :local_game_move, operation_id: "categories-finish-#{steps}",
          revision: status['revision'], move_selection: choice)
        assert_equal(:confirmed, result[:state], result.inspect)
        acted = true
      end
      break if acted || finished
    end
    assert(acted || finished, 'No legal action available before Categories finished')
  end
  with_individual_execution(fixture, record, owner) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(!winning, result[:effect]['summary']['draw'])
    assert_equal(winning ? ['alpha'] : [], result[:effect]['summary']['winners'])
    assert_equal(scores, result[:effect]['summary']['scores'])
    assert_equal(winning ? [2, *Array.new(names.size - 1, 0)] : Array.new(names.size, 1), execution.progress['standings'].map { |row| row['points'] })
    assert_equal(scores.values.sort.reverse, execution.progress['standings'].map { |row| row['score_for'] })
    path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
    bytes = File.binread(path)
    assert_equal({}, JSON.parse(bytes)['busy'])
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: 'categories-complete'))
    probe = File.expand_path('../support/tournament_game_finish_probe.rb', __dir__)
    output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'categories', 'categories-complete', status['event_count'].to_s, winning ? 'alpha' : ''], err: [:child, :out], &:read)
    assert($?.success?, output)
    assert_equal(bytes, File.binread(path))
  end
end
puts "PASS complete Categories: #{names.size} rotating judges, private sheets, real assessments, #{winning ? 'win' : 'shared draw'} and declared small scores #{scores.inspect}"
