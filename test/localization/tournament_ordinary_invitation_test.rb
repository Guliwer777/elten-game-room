# encoding: UTF-8
require_relative '../support/assertions'
require_relative '../../lib/game_room_localization'
include GameRoomTest::Assertions

messages = [
  "Another player is creating this match's table. Accept their invitation or try again shortly.",
  "This match was started or its state is uncertain. Resume the saved game or check Operations before playing again.",
  "Leave your current table before opening another tournament match.",
  "%{sender} invites you to a tournament match (%{game}).",
  "%{sender} invites you to resume a tournament match (%{game})."
]
root = File.expand_path('../..', __dir__)
%w[pl cs es ru].each do |language|
  catalog = GameRoomLocalization::Catalog.new(File.binread(File.join(root, 'locale', language.upcase + '.mo')))
  translator = GameRoomLocalization::Translator.new(catalogs: {language => catalog}, primary: language, known: [])
  messages.each do |source|
    translated = translator.translate(source.b)
    assert(translated != source && !translated.empty?, "Missing #{language}: #{source}")
    assert(translated.encoding == Encoding::UTF_8 && translated.valid_encoding?, "Invalid #{language} encoding")
  end
end
english = GameRoomLocalization::Translator.new(catalogs: {}, primary: 'en', known: [])
messages.each {|source| assert_equal(source, english.translate(source.b))}
puts 'PASS ordinary tournament invitation messages: PL/CS/ES/RU compiled catalogs and binary-source EN fallback'
