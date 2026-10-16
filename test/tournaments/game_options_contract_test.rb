# encoding: UTF-8
require_relative '../support/tournament_public_ui'
require_relative '../support/tournament_match_data'
require_relative '../../lib/tournaments/public_text'
require_relative '../../lib/tournaments/match_binding'

GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
registry = GameRoomGames::CATALOG
view = GameRoomTournaments::PublicText.new(registry: registry, mode_label: 'Test', actor: 'Alice')

def check_options(registry, view, id, options)
  game = registry.build(id)
  count = game.tournament_capabilities(options: options).fetch(:player_counts).first
  raise "Invalid fixture: #{id} #{options.inspect}" unless count
  before = Marshal.dump(options)
  row = TournamentPublicUI.publication(game: id, options: options, 'players_per_match' => count)
  canonical = JSON.parse(row.fetch('settings_json')).fetch('game_options')
  assert_equal(game.normalize_options(options), canonical, "Changed rules: #{id}")
  snapshot = TournamentPublicUI.snapshot([row])
  assert_equal(1, snapshot.fetch('announcements').length, "Rejected own publication: #{id}")
  description = view.description(snapshot.fetch('announcements').first, snapshot)
  game.effective_option_definitions(canonical).each do |definition|
    next unless game.option_visible?(definition, canonical, normalize: false)
    value = canonical.fetch(definition.key.to_s, definition.default)
    expected = case definition.kind.to_sym
    when :boolean then value ? 'Yes' : 'No'
    when :choice then definition.choices.find { |choice| choice.value.eql?(value) }.label
    when :multiple_choice, :multiple_values
      choices = definition.choices.each_with_index.filter_map do |choice, index|
        selected = definition.kind.to_sym == :multiple_values ? value.include?(choice.value) : (value & (1 << index)) != 0
        choice.label if selected
      end
      choices.empty? ? 'None' : choices.join(', ')
    else
      definition.summary_unit == :seconds ? "#{value} seconds" : value.to_s
    end
    label = GameRoomContent.utf8(definition.summary_label || definition.label)
    assert(description.include?("#{label}: #{expected}"), "Incorrect #{id}/#{definition.key}: #{description}")
  end
  names = %w[Alice Bob Carol Dave Eve Frank Grace Heidi].first(count)
  payload = TournamentMatchFixture.payload(game_id: id, names: names)
  payload['options'] = canonical
  binding = GameRoomTournaments::MatchBinding.build(payload, registry: registry)
  assert_equal(canonical, binding.to_h.fetch('options'), "Changed match options: #{id}")
  assert_equal(before, Marshal.dump(options), "Mutated input: #{id}")
end

# Regression: all three omitted booleans are legitimate defaults, not corrupt data.
game = registry.build('mille_bornes')
check_options(registry, view, game.id, game.default_options)
flags = %w[counterflow include_safeties custom_deck include_instant_repairs]
[true, false].repeated_permutation(flags.length).each do |values|
  raw = flags.zip(values).to_h
  check_options(registry, view, game.id, game.normalize_options(raw))
  # Explicit defaults may be omitted by the game, but their meaning is unchanged.
  check_options(registry, view, game.id, raw)
end

# The same paths for every registered game and each declared option kind.
checked = 0
registry.ids.each do |id|
  game = registry.build(id)
  base = game.default_options
  candidates = [base]
  game.effective_option_definitions(base).each do |definition|
    next unless game.option_visible?(definition, base, normalize: false)
    values = case definition.kind.to_sym
    when :boolean then [true, false]
    when :choice then definition.choices.map(&:value)
    when :multiple_values then [definition.default] + definition.choices.map { |choice| [choice.value] }
    when :integer then [0, 1, definition.default.to_i + 1]
    else []
    end
    values.uniq.each { |value| candidates << base.merge(definition.key.to_s => value) }
  end
  candidates.each do |raw|
    options = game.normalize_options(raw)
    changes = game.option_editor_changes(base, options)
    options = game.normalize_options(options.merge(changes)) unless changes.empty?
    next if game.tournament_capabilities(options: options).fetch(:player_counts).empty?
    check_options(registry, view, id, options)
    checked += 1
  end
end
assert(checked >= 400, 'The catalog option matrix unexpectedly lost coverage')

# Reject malformed values before permissive game normalizers can repair them.
bad = [
  ['mille_bornes', {'include_safeties' => 'false'}],
  ['mille_bornes', {'custom_deck' => 1}],
  ['mille_bornes', {'include_instant_repairs' => nil}],
  ['mille_bornes', {'custom_deck' => true, '25_cards' => '10'}],
  ['mille_bornes', {'custom_deck' => true, '25_cards' => 10.0}],
  ['mille_bornes', {'counterflow' => true, 'counterflow_cards' => true}],
  ['mille_bornes', {'unknown_option' => true}],
  ['duck_racing', {'challenges' => ['not_installed']}],
  ['duck_racing', {'challenges' => [1]}],
  ['duck_racing', {'question_sets' => 'quiz.wikidata'}],
  ['duck_racing', {'question_sets' => ['not_installed']}],
  ['duck_racing', {'question_language' => 'not_installed'}]
]
bad.each do |id, options|
  before = Marshal.dump(options)
  error = assert_raises(GameRoomTournaments::Publication::Invalid) do
    TournamentPublicUI.publication(game: id, options: options)
  end
  assert_equal(:invalid_options, error.code, "Wrong validation boundary: #{id} #{options.inspect}")
  assert_equal(before, Marshal.dump(options))
end

# Published/bound data must still be canonical: do not expand compact defaults
# in stored documents or accept an incomplete/altered match binding.
row = TournamentPublicUI.publication(game: 'mille_bornes')
settings = JSON.parse(row.fetch('settings_json'))
settings.fetch('game_options')['include_safeties'] = true
row['settings_json'] = JSON.generate(settings)
projected = GameRoomTournaments::Publication.project(rows: [row], registry: registry, complete: true)
assert_equal([], projected.fetch('announcements'))
assert(projected.fetch('diagnostics').any? { |item| item['code'] == 'incomplete_game_options' })
payload = TournamentMatchFixture.payload(game_id: 'mille_bornes')
payload.fetch('options')['include_safeties'] = true
assert_raises(GameRoomTournaments::Publication::Invalid) { GameRoomTournaments::MatchBinding.build(payload, registry: registry) }

puts "PASS shared option contract: #{registry.ids.length} games, #{checked} valid catalog configurations, 32 compact/explicit deck variants, validation and canonical match bindings"
