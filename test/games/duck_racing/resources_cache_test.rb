require_relative '../../support/assertions'
require_relative '../../../games/duck_racing_support/resources'

include GameRoomTest::Assertions
cache = GameRoomDuckRacing::Resources
adapter = GameRoomDuckRacing::QuestionSets
checks = 0
make_registry = lambda do |correct = 'four'|
  registry = GameRoomContent::Registry.new
  registry.register_language(GameRoomContent::LanguageProfile.new(id: 'en', label: 'English',
    alphabet: ('a'..'z').to_a, normalizer: ->(text) { checks += 1; text.downcase }))
  %w[first second].each do |id|
    registry.register_pack(GameRoomContent::Pack.new(id: "test.#{id}", set_id: "test.#{id}",
      kind: 'quiz', language_id: 'en', version: 1, title: id, game_ids: ['quiz'],
      data: {'questions' => [{'id' => id, 'category' => 'Example', 'prompt' => 'Which answer?',
        'correct' => correct, 'wrong' => %w[one two three]}]}))
  end
  registry
end
options = {'question_language' => 'en', 'question_sets' => %w[test.first test.second]}
registry = make_registry.call
prepared = cache.prepare(options, registry: registry)
assert_equal(8, checks, 'The first preparation must validate every question')
assert(prepared.frozen? && prepared[:questions].frozen?)
expected = prepared[:questions].draw(seed: 21)
10.times do
  again = cache.prepare(options.merge('question_sets' => options['question_sets'].reverse), registry: registry)
  assert(again.equal?(prepared), 'A fresh game/options object revalidated unchanged resources')
  assert_equal(expected, again[:questions].draw(seed: 21))
end
assert_equal(8, checks, 'Warm lookups revisited question answers')
%w[missing pl-PL].each do |language|
  assert_raises(adapter::Unavailable) { cache.prepare(options.merge('question_language' => language), registry: registry) }
end
[:en, '', nil].each do |language|
  assert_raises(adapter::Unavailable) { cache.prepare(options.merge('question_language' => language), registry: registry) }
end
[[], ['test.first', 'test.first'], ['missing']].each do |ids|
  assert_raises(adapter::Unavailable) { cache.prepare(options.merge('question_sets' => ids), registry: registry) }
end
other = make_registry.call('five')
changed = cache.prepare(options, registry: other)
assert(!changed.equal?(prepared), 'Equal IDs/version labels reused a different registry content')
assert_equal(16, checks)
draw = changed[:questions].draw(seed: 21)
assert_equal('five', draw[:choices][draw[:correct_index]])
assert(changed[:fingerprint] != prepared[:fingerprint])

# Equal pack objects with a different normalizer still require validation.
profile_registry = GameRoomContent::Registry.new
profile_registry.register_language(GameRoomContent::LanguageProfile.new(id: 'en', label: 'English',
  alphabet: ('a'..'z').to_a, normalizer: ->(_text) { 'same' }))
registry.packs.each { |pack| profile_registry.register_pack(pack) }
assert_raises(adapter::Unavailable) { cache.prepare(options, registry: profile_registry) }
invalid = make_registry.call('One')
2.times { assert_raises(adapter::Unavailable) { cache.prepare(options, registry: invalid) } }

# Bounded by selection, not by game object or table count; evicted entries
# simply undergo full validation again. Concurrent cold callers agree.
fresh = make_registry.call
threads = Array.new(6) { Thread.new { cache.prepare(options, registry: fresh) } }
values = threads.map(&:value)
assert(values.all? { |value| value.equal?(values.first) })
(cache::MAX_SELECTIONS + 2).times { cache.prepare(options, registry: make_registry.call) }
assert_equal(cache::MAX_SELECTIONS, cache.instance_variable_get(:@prepared).size)
before = checks
again = cache.prepare(options, registry: registry)
assert_equal(before + 8, checks, 'An evicted selection skipped validation')
assert_equal(expected, again[:questions].draw(seed: 21))
puts 'PASS Duck resources: shared immutable validated selection, language/scope guards, reload identity, invalid data, concurrency and bounded eviction'
