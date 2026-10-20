require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_text'

SCORING_RULE = 'Each match awards 2 tournament points per opponent beaten and 1 per tied opponent. Teams count as single opponents.'.freeze
LANGUAGES = %w[en pl cs es ru].freeze

def localized(source)
  GameRoomContent.utf8(GameRoomLocalization.translate(source))
end

def render_rules(rules)
  row = TournamentPublicUI.publication.merge('rules' => rules)
  snapshot = TournamentPublicUI.snapshot([row])
  publication = snapshot.fetch('announcements').first
  before = Marshal.dump(snapshot)
  formatter = GameRoomTournaments::PublicText.new(registry: GameRoomGames::CATALOG,
    mode_label: 'Server tournament', actor: 'Reader')
  rendered = formatter.description(publication, snapshot)
  assert_equal(before, Marshal.dump(snapshot), 'Displaying rules changed the publication or its projection')
  assert_equal(rules, publication.fetch('rules'), 'Displaying rules replaced authored rules')
  rendered
end

translations = LANGUAGES.to_h do |language|
  GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
  [language, localized(SCORING_RULE)]
end
assert_equal(LANGUAGES.length, translations.values.uniq.length, 'A required scoring translation was not loaded')

LANGUAGES.each do |language|
  GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => [language]})
  scoring = translations.fetch(language)
  label = localized("Organizer's notes")

  text = render_rules(scoring)
  assert_equal(1, text.scan(scoring).size, "#{language}: default scoring is displayed twice")
  assert(!text.include?("#{label}:"), "#{language}: automatic scoring was presented as organizer notes")

  # The comparison applies to the entire text, not a sentence or substring.
  # Do not silently edit, strip or collapse the organizer's custom wording.
  ["Additional rule. #{scoring}", "#{scoring}\r\nCustom closing rule.",
    "#{scoring}\r\n#{scoring}", " #{scoring} "].each do |custom|
    text = render_rules(custom)
    assert(text.include?("#{label}: #{custom}"), "#{language}: custom rules were altered")
    assert_equal(custom.scan(scoring).size + 1, text.scan(scoring).size,
      "#{language}: a partial match removed the separate authoritative scoring explanation")
  end

  foreign = translations.fetch(language == 'en' ? 'pl' : 'en')
  text = render_rules(foreign)
  assert(!text.include?("#{label}:"), "#{language}: foreign automatic scoring became organizer notes")
  assert_equal(0, text.scan(foreign).size)
  assert_equal(1, text.scan(scoring).size, "#{language}: localized scoring explanation is missing")
end

puts 'PASS automatic scoring follows the viewer in five languages; custom wording and immutable publications preserved'
