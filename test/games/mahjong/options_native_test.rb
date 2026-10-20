require_relative '../../support/game_option_editor_native'
require_relative '../../support/mahjong_options_game'
require_relative '../../support/assertions'
include GameRoomTest::Assertions

%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  game = MahjongOptionsTest::Game.new
  if language == 'pl'
    assert_equal('Odmiana Mahjonga', game.option_definitions.first.label)
    assert_equal('Długość meczu Riichi', game.option_definitions.find { |entry| entry.key == 'riichi_winds' }.label)
  end
  driver = NativeOptionTest::Driver.new(game, initial_options: game.default_options)
  assert(driver.visible?('layout') && !driver.visible?('riichi_seats'))
  assert(!driver.visible?('hong_kong_winds') && !driver.visible?('bot_delay'))
  variant = driver.focus('variant')
  original_form = driver.form
  driver.press([40])
  assert(driver.visible?('hong_kong_winds') && !driver.visible?('layout'))
  assert_equal(2, driver.control('hong_kong_winds').index, 'Missing inactive preference must use the declared full-match default')
  driver.press([40])
  assert(driver.visible?('riichi_seats') && driver.visible?('riichi_winds'))
  assert(!driver.visible?('hong_kong_winds') && driver.visible?('bot_delay'))
  assert_equal(2, driver.control('riichi_winds').index)
  driver.focus('riichi_seats')
  driver.press([40])
  driver.focus('variant')
  driver.press([40])
  assert(driver.visible?('mcr_winds') && !driver.visible?('riichi_seats'))
  assert_equal(1, driver.control('mcr_winds').index)
  assert(driver.form.equal?(original_form) && driver.form.fields[driver.form.index].equal?(variant))
  driver.press([38])
  driver.focus(driver.form.accept_button)
  driver.press([13])
  result = driver.finished
  assert_equal('riichi', result['variant'])
  assert_equal(3, result['seats'])
  assert_equal(2, result['match_winds'])
  assert(!result.key?('layout') && !result.key?('mcr_winds') && !result.key?('hong_kong_winds'))
  assert(driver.program.alerts.empty?)
end
puts 'PASS native Mahjong options EN/PL/CS/ES/RU: arrows change variant, only matching fields, defaults, Tab focus and sanma save'
