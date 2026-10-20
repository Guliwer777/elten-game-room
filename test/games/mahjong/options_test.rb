require_relative '../../support/assertions'
require_relative '../../support/mahjong_options_game'
include GameRoomTest::Assertions

game = MahjongOptionsTest::Game.new
expected = {
  'solitaire'=>[%w[variant layout], 1, 0],
  'hong_kong'=>[%w[variant hong_kong_winds bot_delay], 4, 4],
  'riichi'=>[%w[variant riichi_seats riichi_winds bot_delay], 4, 2],
  'mcr'=>[%w[variant mcr_winds bot_delay], 4, 4]
}
expected.each do |variant, (keys, seats, winds)|
  values = game.normalize_options('variant'=>variant, 'seats'=>8, 'match_winds'=>99, 'layout'=>'flat', 'riichi_seats'=>'4')
  definitions = game.effective_option_definitions(values)
  visible = definitions.select { |definition| game.option_visible?(definition, values) }.map(&:key)
  assert_equal(keys, visible)
  assert_equal(seats, values['seats'])
  assert_equal(winds, values['match_winds'])
  assert_equal(values, game.options_from_json(JSON.generate(values)))
  assert_equal(nil, game.validation_error(values, player_count: seats))
  assert(game.validation_error(values, player_count: seats + 1))
  assert_equal(variant == 'solitaire' ? nil : 32_768, game.session_history_capacity(values))
  assert_equal('variant', definitions.first.key)
end
sanma = game.normalize_options('variant'=>'riichi', 'riichi_seats'=>'3', 'riichi_winds'=>'1')
assert_equal(3, sanma['seats'])
assert_equal(1, sanma['match_winds'])
assert_equal(nil, game.validation_error(sanma, player_count: 3))
%w[hong_kong mcr].each do |variant|
  switched = game.normalize_options(sanma.merge('variant'=>variant))
  assert_equal(4, switched['seats'])
  assert(!switched.key?('riichi_seats') && !switched.key?('riichi_winds'))
end
assert_equal('terraces', game.default_options['layout'])
puts 'PASS Mahjong variant options: conditional fields, real seat counts, match lengths, inactive option isolation and saved settings'
