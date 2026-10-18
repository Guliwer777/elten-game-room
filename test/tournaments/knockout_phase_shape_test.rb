require_relative '../support/tournament_fixed_teams'
require_relative '../../lib/tournaments/local_knockout_plan'
include TournamentFixedTeamsSupport

names = %w[Ala Anna Bartek Beata Celina Cezary Darek Dorota]
context, _service, reference = fixture(names: names, rematch: false,
  group_advancement: T::GroupAdvancement::AUTOMATIC)
checks = 0
with_backend(context) do |backend, _reopen, _session, _authority, directory|
  record = backend.accept(preview: backend.preview_pairs(publication_ref: reference,
    pairs: names.each_slice(2).to_a, team_template: TEMPLATE, intent_id: 'phase-shape'))
  intent = record['preview']['intent_id']
  # Pure group-result projections only. The caller of LocalKnockoutPlan owns
  # the real execution transaction; these summaries are not game receipts.
  receipts = record['evidence']['plan']['matches'].map do |match|
    teams = match['players'].map { |person| person['team'] }.uniq
    {'record_intent'=>intent, 'match_id'=>match['match_id'], 'leg'=>match['leg'],
      'summary'=>{'winner'=>teams.first, 'scores'=>{teams.first=>10, teams.last=>-2}}}
  end
  preview = T::KnockoutPhase.build(record: record, receipts: receipts)
  T::KnockoutPhase.shape!(preview)
  input = JSON.generate(preview)
  parent_reads = 0
  store = T::LocalKnockoutPlan.new(directory: directory, identity: backend.identity,
    actor: 'organizator', guard: -> {}, parent_reader: ->(id, _fresh) { parent_reads += 1; id == intent ? record : nil })
  accepted = store.accept(preview: preview, current: preview)
  assert_equal(accepted, store.accept(preview: preview, current: preview))
  assert_equal(accepted, store.readback(parent_intent: intent))
  path = store.instance_variable_get(:@storage).path
  original = File.binread(path)
  [nil, true, false, 7, 1.5, [], 'bad'].each do |value|
    bad = JSON.parse(input)
    bad['plan'] = value
    unchanged = JSON.generate(bad)
    reads = parent_reads
    error = assert_raises(T::Publication::Invalid) { T::KnockoutPhase.shape!(T::KnockoutPhase.frozen_copy(bad)) }
    assert_equal(:invalid_fields, error.code)
    error = assert_raises(T::Publication::Invalid) { store.accept(preview: bad, current: preview) }
    assert_equal(:invalid_fields, error.code)
    assert_equal(reads, parent_reads, 'Malformed shape must fail before the parent lookup')
    assert_equal(original, File.binread(path), 'Malformed acceptance must not modify the approved file')
    document = JSON.parse(original)
    document['records'].first['preview'] = bad
    damaged = JSON.generate(document)
    begin
      File.binwrite(path, damaged)
      error = assert_raises(T::Publication::Invalid) { store.readback(parent_intent: intent) }
      assert_equal(:invalid_fields, error.code)
      assert_equal(damaged.b, File.binread(path), 'A damaged document must not be rewritten')
    ensure
      File.binwrite(path, original)
    end
    assert_equal(unchanged, JSON.generate(bad), 'Validation must not normalize the input')
    checks += 3
  end
  assert_equal(input, JSON.generate(preview))
  assert_equal(accepted, store.readback(parent_intent: intent))
  assert_equal(original, File.binread(path))
end
puts "PASS knockout phase shapes: #{checks} typed refusals, valid approval/retry/cold read, no input or stored-byte changes; local projection only"
