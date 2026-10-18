require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
include GameRoomTest::Assertions

assert(EltenGameRoom::GAME_REGISTRY.ids.include?('mahjong'), 'Mahjong is absent from the installed catalog')
%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  %w[solitaire hong_kong riichi mcr].each_with_index do |variant, index|
    game = EltenGameRoom::GAME_REGISTRY.build('mahjong')
    assert(game.required_decision_key(nil, 'Alice').nil?, 'First presentation compared a missing prior replay incorrectly')
    driver = NativeOptionTest::Driver.new(game, creating_table: true)
    driver.focus('variant')
    index.times { driver.press([40]) }
    assert(driver.visible?('layout') == (variant == 'solitaire'))
    assert(driver.visible?('riichi_seats') == (variant == 'riichi'))
    driver.focus(driver.form.accept_button)
    driver.press([13])
    selected = driver.finished.fetch(:game_options)
    assert_equal(variant, selected['variant'])
    book = game.rule_book(options: selected)
    assert(book.sections.length > 10 && book.sections.last.id == :controls)
    %i[table_hand table_hk_sets table_yaku table_fu table_riichi_payments table_mcr_sets table_winds].each do |chapter|
      assert(book.sections.any? { |section| section.id == chapter && !section.paragraphs.empty? },
        "Missing detailed Mahjong chapter #{chapter} for #{language}/#{variant}")
    end
    assert_equal([:rules, :controls, :current_options], book.documents.map(&:id))
    assert(book.sections.all? { |section| section.paragraphs.all? { |text| text.encoding == Encoding::UTF_8 && text.valid_encoding? } })
    assert(driver.program.alerts.empty?)
  end
end
puts 'PASS actual Mahjong catalog EN/PL/CS/ES/RU: all four native creation flows, declared defaults and complete rules/options documents'
