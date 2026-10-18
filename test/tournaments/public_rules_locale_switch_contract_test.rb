require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_text'

module PublicRulesLocaleSwitchContract
  SCORING = 'Each match awards 2 tournament points per opponent beaten and 1 per tied opponent. Teams count as single opponents.'.freeze
  LANGUAGES = %w[en pl cs es ru].freeze

  def self.language(id)
    GameRoomLocalization.boot(settings: {'interface_language' => id, 'known_languages' => [id]})
  end

  def self.translated(value)
    GameRoomContent.utf8(GameRoomLocalization.translate(value))
  end

  translations = LANGUAGES.to_h { |id| language(id); [id, translated(SCORING)] }
  assert_equal(5, translations.values.uniq.length, 'Required scoring translations did not load')
  formatter = GameRoomTournaments::PublicText.new(registry: GameRoomGames::CATALOG,
    mode_label: 'Read-only review', actor: 'Reader')
  count = 0
  LANGUAGES.each do |source_language|
    rules = translations.fetch(source_language)
    source = TournamentPublicUI.publication.merge('rules' => rules)
    snapshot = TournamentPublicUI.snapshot([source])
    publication = snapshot.fetch('announcements').first
    assert(publication, 'The fixture publication failed real validation')
    # Preserve a genuinely validated value, but exercise the formatter's
    # binary-string boundary separately from JSON wire validation.
    snapshot = Marshal.load(Marshal.dump(snapshot))
    publication = snapshot.fetch('announcements').first
    publication['rules'] = publication.fetch('rules').dup.force_encoding(Encoding::ASCII_8BIT)
    GameRoomTournaments::Publication::Data.freeze_tree(snapshot)
    bytes = Marshal.dump(snapshot)
    LANGUAGES.each do |viewer_language|
      language(viewer_language)
      scoring = translations.fetch(viewer_language)
      description = formatter.description(publication, snapshot)
      assert_equal(Encoding::UTF_8, description.encoding, 'Displayed rules are not UTF-8')
      assert(description.valid_encoding?, 'Displayed rules contain invalid bytes')
      assert(description.include?("#{translated('Tournament rules')}: #{rules}"),
        'Authored complete rules or their translated heading disappeared')
      assert_equal(1, description.scan(scoring).length,
        "#{source_language}->#{viewer_language}: authoritative local scoring is missing or duplicated")
      assert_equal(1, description.scan(rules).length,
        "#{source_language}->#{viewer_language}: original authored rules were altered")
      assert_equal(bytes, Marshal.dump(snapshot), 'Locale change modified an immutable publication')
      count += 1
    end
  end

  # A translation with additional non-ASCII content and a
  # nonbreaking prefix are not an exact replacement for the authored rules.
  LANGUAGES.each do |viewer_language|
    language(viewer_language)
    scoring = translations.fetch(viewer_language)
    ["\u00a0#{scoring}", "#{scoring}\u200b", "Żółć: #{scoring}"].each do |custom|
      row = TournamentPublicUI.publication.merge('rules' => custom)
      snapshot = TournamentPublicUI.snapshot([row])
      publication = snapshot.fetch('announcements').first
      assert(publication, 'The custom fixture publication failed real validation')
      before = Marshal.dump(snapshot)
      description = formatter.description(publication, snapshot)
      assert(description.include?("#{translated('Tournament rules')}: #{custom}"), 'Custom text was normalized away')
      assert_equal(2, description.scan(scoring).length, 'A partial match suppressed the authoritative scoring paragraph')
      assert_equal(before, Marshal.dump(snapshot), 'Partial-match handling mutated the source')
      count += 1
    end
  end
  puts "PASS public rules locale-switch contract: #{count} independent cases, binary strings, immutable sources and exact-only deduplication"
end
