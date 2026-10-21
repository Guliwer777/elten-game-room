require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../../games/mahjong_support/mcr_patterns'
include GameRoomTest::Assertions

%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  game = EltenGameRoom::GAME_REGISTRY.build('mahjong')
  book = game.rule_book(options: game.normalize_options('variant'=>'mcr'))
  sections = book.sections.to_h { |section| [section.id.to_s, section] }
  rows = book.sections.select { |section| section.id.to_s.start_with?('table_mcr_fan_') }.flat_map(&:paragraphs)
  assert_equal(81, rows.length, "#{language}: MCR catalog incomplete")
  actual = rows.to_h do |row|
    match = /\A- MCR (\d+): (\d+) (?:fan|фан) — (.+)\z/.match(row)
    assert(match, "#{language}: unreadable MCR entry #{row}")
    [match[1].to_i, match[2].to_i]
  end
  assert_equal((1..81).to_a, actual.keys.sort)
  actual.each { |id, value| assert_equal(GameRoomMahjong::MCRPatterns::POINTS.fetch(id - 1), value, "#{language}: wrong fan for MCR #{id}") }
  assert(sections.fetch('table_mcr_mixed_kongs').paragraphs.join.include?('6'))
  assert(sections.fetch('table_mcr_exclusions').paragraphs.length > 40)
  hk = book.sections.select { |section| section.id.to_s.start_with?('table_hk_fan_') }.flat_map(&:paragraphs)
  assert_equal(29, hk.length, "#{language}: HK catalog incomplete")
  assert_equal(28, sections.fetch('table_yaku').paragraphs.count { |paragraph| paragraph.start_with?('- ') })
  assert_equal(10, sections.fetch('table_riichi_yakuman').paragraphs.count { |paragraph| paragraph.start_with?('- 1 yakuman') })
  assert(sections.key?('table_fu') && sections.key?('solitaire_points'))
  assert(sections.keys.none? { |id| id.end_with?('_practice') }, 'Worked-example chapters were retained')
  assert(book.sections.all? { |s| s.paragraphs.none? { |p| p.start_with?('|') } }, 'Raw Markdown table in native instructions')
  assert(book.sections.last.id == :controls)
end
puts 'PASS complete scoring references: 81 MCR entries and values, 29 HK awards, 28 ordinary Riichi yaku, ten active yakuman, native bullets and all five languages'
