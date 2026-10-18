require_relative '../support/assertions'
require_relative '../../games/catalog'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})

invalid = [true, false, 1, 'teams', {}, [true], [{}], [[]], [Float::INFINITY], [Float::NAN]]
count = 0
GameRoomGames::CATALOG.ids.each do |id|
  game = GameRoomGames::CATALOG.build(id)
  defaults = game.default_options
  invalid.each do |seats|
    options = defaults.merge('team_seats' => seats)
    original = Marshal.dump(options)
    assert_raises(ArgumentError) { game.normalize_options(options) }
    assert_equal('The game settings are invalid.', game.validation_error(options, player_count: game.minimum_players))
    assert_raises(ArgumentError) { game.rules_options_text(options) }
    assert_equal(original, Marshal.dump(options), 'Shape validation mutated options')
    count += 1
  end
  [[], [nil, '0', 1.9, '1'], [0, 0, 1, 1], [-1, 2], ['invalid', '2junk']].each do |seats|
    normalized = game.normalize_options(defaults.merge('team_seats' => seats))
    assert_equal(seats.map(&:to_i), normalized['team_seats'], 'A nonthrowing historical conversion changed')
  end

  # Compare the exact legacy scalar conversion, including finite Float values
  # for which value.to_s.to_i would not preserve value.to_i.
  [nil, 0, -1, 5.7, 1e22, '12', 'not a number'].each do |value|
    game.effective_option_definitions(defaults).select { |item| item.kind.to_sym == :multiple_choice }.each do |definition|
      expected = value.to_i & ((1 << definition.choices.length) - 1)
      actual = game.normalize_options(defaults.merge(definition.key.to_s => value))
      assert_equal(expected, actual[definition.key.to_s], 'A historical bitmask conversion changed')
    end
  end
  game.effective_option_definitions(defaults).select { |item| item.kind.to_sym == :multiple_choice }.each do |definition|
    [true, false, {}].each do |value|
      actual = game.normalize_options(defaults.merge(definition.key.to_s => value))
      assert_equal(0, actual[definition.key.to_s], 'An unsupported mask type was not safely normalized')
      assert(!GameRoomOptionValues.valid?(definition, value), 'Strict published option validation was weakened')
    end
  end
  next if game.content_pack_kind.to_s.empty?

  [true, false, {}, []].each do |version|
    options = defaults.merge(GameRoomContent::PACK_VERSION_KEY => version)
    normalized = game.normalize_options(options)
    assert_equal(0, normalized[GameRoomContent::PACK_VERSION_KEY])
    assert(game.validation_error(options), 'Invalid content version passed raw validation')
    assert(game.validation_error(normalized), 'Invalid content version became a valid pack after normalization')
    assert_equal(nil, game.selected_content_pack(options))
  end
end
assert(count >= 350, 'The complete catalog shape matrix lost coverage')
puts "PASS #{count} rejected shared team shapes, historical coercions, masks and content versions across the game catalog"
