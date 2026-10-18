require_relative '../../support/categories'
require_relative '../../support/sequence_random'

game = GameRoomGames::Categories.new
players = %w[Alice Bob Carol]
repository = CategoriesRepository.new(players)
options = game.normalize_options(game.default_options.merge(
  'category_set' => 'custom', 'custom_categories' => %w[country city],
  'round_category_count' => 2, 'round_time' => 90, 'target_score' => 100))
session = {'options' => JSON.generate(options)}
context = GameRoomGames::ActionContext.new(session_id: 901, table_id: 902, now: 100,
  hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),
  random_source: GameRoomRandom::SequenceSource.new([1]))
events = []

commit = lambda do |actor, selection = nil|
  replay = game.replay(session, events, repository)
  selection ||= game.automatic_action(replay, actor, context: context)
  assert(selection, "No automatic action for #{actor} in #{replay.state[:phase]}")
  status, plan = game.action_for(selection, replay, actor, context: context)
  assert(status == :ok, "Setup action rejected for #{actor}: #{status}")
  append_plan(events, plan, actor, now: context.now)
  game.replay(session, events, repository)
end

commit.call('Alice')
commit.call('Bob', surface_action('answer_sheet', 'submit',
  'answers' => {'country' => 'Austria', 'city' => 'Athens'}))
commit.call('Carol', surface_action('answer_sheet', 'submit',
  'answers' => {'country' => 'Argentina', 'city' => 'Athens'}))
commit.call('Alice')
commit.call('Bob')
commit.call('Carol')
review = commit.call('Alice')
assert(review.state[:phase] == :review, 'The fixture did not reach authentic committed/revealed review')

# Historical commits have positional codes, not keyed decisions. This is the
# established player-first wire order: Austria, Athens (Bob and Carol), Argentina.
# Presentation sorting must never reinterpret an already accepted commit.
events << {'id' => events.length + 1, 'actor' => 'Alice', 'action' => 'review_commit',
  'value' => 'udi', 'created_at' => context.now}
reviewed = game.replay(session, events, repository)
assert(reviewed.accepted_events.length == events.length,
  'Category-first display reinterpreted the established positional review_commit')
assert(reviewed.state[:decisions] == {'1:0:0' => 'unique', '1:0:1' => 'duplicate', '1:1:0' => 'incorrect'},
  'Historical grades moved to another answer while sorting the display')

scored = commit.call('Alice')
assert(scored.state[:scores] == {'Alice' => 0, 'Bob' => 3, 'Carol' => 1},
  'Display ordering changed scores reconstructed from an old accepted grade sequence')
assert(scored.accepted_events.length == events.length, 'The completed historical round lost accepted events')

surface = game.surface_spec(review, 'Alice')
surface = surface.parts.map(&:surface).find { |part| part.is_a?(GameSurfaces::ReviewSpec) } if surface.is_a?(GameSurfaces::CompositeSpec)
assert(surface.items.map(&:category) == %w[Country Country City],
  'The review still presents all categories of one player before the next player')
assert(surface.items.map(&:answer) == %w[Austria Argentina Athens],
  'Category-first review reordered or duplicated a grouped answer')
assert(surface.items.map(&:id) == %w[1:0:0 1:1:0 1:0:1],
  'Presentation changed the stable review identity rather than only its visible order')
assert(surface.items.last.status == 'identical answer from 2 players',
  'Category-first review lost the identical-answer group')

puts 'PASS Categories: category-first display, stable IDs/grouping, historical mixed positional grades and scores preserved'
