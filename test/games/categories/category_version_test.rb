require_relative '../../support/categories'
require_relative '../../support/sequence_random'

game = GameRoomGames::Categories.new
klass = GameRoomGames::Categories
removed = %w[surname famous_person building invention chemical_element]
added = %w[drink known_athlete tool known_actor known_writer]
assert(klass::CATEGORY_IDS.first(27) == klass::LEGACY_HARD_CATEGORY_IDS, 'Historical category mask positions moved')
assert(klass::CATEGORY_IDS.last(5) == added, 'New wire categories must be appended')
assert(klass::HARD_CATEGORY_IDS.size == 27 && klass::MEDIUM_CATEGORY_IDS.size == 18, 'Pool sizes changed')
assert((klass::HARD_CATEGORY_IDS & removed).empty?, 'A retired category is still offered')
assert((added - klass::HARD_CATEGORY_IDS).empty?, 'A selected replacement is missing')
assert(game.default_options['category_version'] == 2, 'New default options did not select the new pools')

legacy = {'category_set'=>'custom', 'custom_categories'=>1 << 9, 'round_category_count'=>1}
old_options = game.normalize_options(legacy)
assert(!old_options.key?('category_version'), 'Historical options acquired a new hashed field')
assert(game.send(:selected_category_pool, old_options) == ['surname'], 'Old custom mask became Drink')
old_def = game.effective_option_definitions(old_options).find { |item| item.key == 'custom_categories' }
assert(old_def.choices[9].value == 'surname', 'Historical option reader reinterpreted a custom bit')
assert(game.options_from_json(JSON.generate(old_options)) == old_options, 'Historical options changed on reload')
legacy_array = game.normalize_options('category_set'=>'custom', 'custom_categories'=>%w[surname building], 'round_category_count'=>2)
assert(game.send(:selected_category_pool, legacy_array) == %w[surname building], 'Legacy string selections were discarded')

fresh = game.table_creation_options('category_set'=>'custom', 'custom_categories'=>%w[drink known_athlete tool known_actor known_writer], 'round_category_count'=>5)
fresh_def = game.effective_option_definitions(fresh).find { |item| item.key == 'custom_categories' }
assert(fresh_def.choices.map(&:value) == klass::HARD_CATEGORY_IDS, 'New custom choices expose retired categories')
assert(game.send(:selected_category_pool, fresh).sort == added.sort, 'New custom selections changed')
assert(game.validation_error(fresh).nil?, 'New category selections are invalid')
assert(JSON.generate(game.default_options).bytesize <= 256, 'New defaults exceed the option size budget')
assert(game.options_from_json(JSON.generate(fresh)) == fresh, 'New masks changed on reload')
assert(game.send(:decode_round_categories, game.send(:encode_round_categories, removed)) == removed,
  'Old round categories no longer decode faithfully')
assert(game.send(:decode_round_categories, game.send(:encode_round_categories, added)) == added,
  'New round categories did not retain their physical wire identities')

players = %w[Alice Bob]
repo = CategoriesRepository.new(players)
context = GameRoomGames::ActionContext.new(session_id: 7, table_id: 4, now: 100,
  hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),
  random_source: GameRoomRandom::SequenceSource.new([1, 1]))
[old_options, fresh].each do |options|
  session = {'options'=>JSON.generate(options)}
  replay = game.replay(session, [], repo)
  selection = game.automatic_action(replay, 'Alice', context: context)
  status, plan = game.action_for(selection, replay, 'Alice', context: context)
  assert(status == :ok, 'Could not start a category-version round')
  events = []
  append_plan(events, plan, 'Alice', now: context.now)
  actual = GameRoomGames::Categories.new.replay(session, events, repo)
  assert(actual.accepted_events.size == events.size, 'Versioned round was rejected on cold replay')
  assert(actual.state[:round_categories] == game.send(:selected_category_pool, options), 'Round used another category dialect')
end

puts 'PASS Categories versions: new choices/pools, append-only round IDs, old options/masks/rounds and new cold replay'
