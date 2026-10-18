# encoding: UTF-8
require_relative '../../tools/support/translation_catalog'
require_relative '../../lib/game_room_localization'

root = File.expand_path('../..', __dir__)
messages = [
  "The match changed. Review the updated consequences before confirming again.",
  "This game does not yet support removing a participant from a tournament match in progress. No result was recorded.",
  "The scores from a completed round are unavailable. No forfeit was recorded.",
  "The current game history is unavailable. Join the table as an observer and try again. No forfeit was recorded.",
  "This match has already been resolved.",
  "The match had not started. The remaining participants share first place.",
  "Forfeit before the match started.",
  "No round was completed. The remaining participants share first place.",
  "Places are based on the scores after the last completed deal.",
  "Places are based on the scores after the last completed round.",
  "Who loses by forfeit?",
  "%{player} loses by forfeit. This ends the match in the tournament.",
  "%{place}. %{player}; tournament points: %{points}",
  "Game scores after the last completed round: %{scores}",
  "Forfeit consequences",
  "%{player} loses by forfeit. Organizer: %{organizer}.",
  "%{player} loses by forfeit after five minutes of absence.",
  "%{player} is eliminated by forfeit. The remaining participants continue playing.",
  "Conflicting match results were recorded. The first complete result remains in effect.",
  "To decide a match in progress, join its table as an observer. A match with unavailable history cannot be decided here.",
  "All combinations",
  "Availability windows",
  "Balanced cycle",
  "Multiplayer pairing",
  "The tournament changed. Refresh its view before changing it again."
]
languages = %w[PL CS ES RU]
languages.each do |language|
  po = GameRoomTranslationCatalog.read_po(File.join(root, "locale/#{language}.po"))
  binary = GameRoomLocalization::Catalog.new(File.binread(File.join(root, "locale/#{language}.mo")))
  messages.each do |message|
    entry = po[nil, message]
    raise "#{language}: missing active PO message #{message}" unless entry &&
      !entry.obsolete? && !entry.fuzzy? && !entry.msgstr.to_s.empty?
    translated = binary.translate(message.b)
    raise "#{language}: missing compiled message #{message}" unless translated && !translated.empty?
    raise "#{language}: stale compiled message #{message}" unless translated == entry.msgstr
    raise "#{language}: invalid UTF-8 #{message}" unless translated.encoding == Encoding::UTF_8 && translated.valid_encoding?
    raise "#{language}: placeholders changed #{message}" unless translated.scan(/%\{[^}]+\}/).sort == message.scan(/%\{[^}]+\}/).sort
    raise "#{language}: untranslated fallback #{message}" if translated == message
  end
end
puts "PASS recent tournament messages: #{messages.size} messages, #{languages.size} languages, exact PO/MO, binary lookup and placeholders"
