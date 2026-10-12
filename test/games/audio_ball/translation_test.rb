require_relative "../../support/binary_rule_dictionary"
require_relative "../../support/authored_rulebooks"
require_relative "../../../lib/audio_ball/audio"

class TranslatedPointSound
  attr_accessor :pan, :volume, :frequency, :position
  def initialize(clock, &played)
    @clock, @played, @frequency = clock, played, 48_000
  end
  def length; 0.35; end
  def playing?; @until && @clock.call < @until; end
  def finished?; !playing?; end
  def play; @until = @clock.call + length; @played.call; end
  def pause; @until = nil; end
  def close; pause; end
end

%w[lib/audio_ball/audio.rb lib/audio_ball/point_audio.rb lib/realtime/score_announcements.rb].each do |name|
  path = File.join(BinaryRulesLoad::ROOT, name)
  raise "Point audio bypassed binary source loading: #{name}" unless BinaryRulesLoad.instance_variable_get(:@loaded)[path]
end

program = Object.new
program.define_singleton_method(:create_sound_from_asset) { |_name, **_options| nil }
dictionary = $rules_dictionary
game = GameRoomGames::AudioBall.new
[:pl, :en, :fallback].each do |language|
  $rules_english = language == :en
  GameRoomTestLocalization.use_language(language)
  $rules_dictionary = language == :fallback ? BinaryRuleDictionary.new({}) : dictionary
  now = 0.0
  audio = GameRoomAudioBall::Audio.new(program, clock: -> { now })
  $spoken_messages.clear
  audio.announce_set(1)
  expected = language == :pl ? 'Pierwszy set.' : 'First set.'
  raise "Missing #{language} set announcement" unless $spoken_messages == [expected]
  audio.hurry('Łucja'.b)
  expected = language == :pl ? 'Łucja, zostało 10 sekund na uderzenie.' : 'Łucja, you have 10 seconds left.'
  raise "Missing #{language} warning or binary name" unless $spoken_messages.last == expected
  $spoken_messages.clear
  audio.point([12, 10], sets: [1, 0], set_finished: true, winner: 0, viewer: 0, finished: true)
  raise "#{language} score skipped the goal pause" unless $spoken_messages.empty?
  now = 3.0
  2.times { audio.tick }
  expected = language == :pl ? 'Wynik: 12 do 10. Wygrywasz set. Sety: 1 do 0. Wygrywasz mecz.' :
    'Score: 12 to 10. You win the set. Sets: 1 to 0. You win the match.'
  raise "Missing #{language} score or match result" unless $spoken_messages.length == 2 && $spoken_messages.join(' ') == expected
  raise "Invalid #{language} speech encoding" unless $spoken_messages.all? { |text| text.encoding == Encoding::UTF_8 && text.valid_encoding? }
  audio.close
  now, played = 0.0, []
  recorded = Object.new
  recorded.define_singleton_method(:create_sound_from_asset) do |name, **_options|
    TranslatedPointSound.new(-> { now }) { played << name }
  end
  audio = GameRoomAudioBall::Audio.new(recorded, clock: -> { now })
  $spoken_messages.clear
  audio.point([7, 5], sets: [3, 1], set_finished: true, winner: 0, viewer: 1, finished: true)
  audio.announce_set(2)
  raise "#{language} result speech overlapped goal recordings" unless $spoken_messages.empty?
  [3.0, 3.5, 4.0].each { |time| now = time; audio.tick }
  raise "#{language} recorded score has the wrong listener order" unless played.last(3) == %w[pong_scores pong_number5 pong_number7]
  raise "#{language} score TTS duplicated recordings" unless $spoken_messages.empty?
  now = 4.5
  audio.tick
  expected = language == :pl ? 'Przegrywasz set. Sety: 1 do 3. Przegrywasz mecz.' :
    'You lose the set. Sets: 1 to 3. You lose the match.'
  raise "Missing #{language} queued set/match result" unless $spoken_messages == [expected]
  audio.tick
  expected = language == :pl ? 'Drugi set.' : 'Second set.'
  raise "Missing #{language} queued ordinal" unless $spoken_messages.last == expected
  raise "Invalid #{language} queued speech encoding" unless $spoken_messages.all? { |text| text.encoding == Encoding::UTF_8 && text.valid_encoding? }
  label = game.option_definitions.find { |definition| definition.key == 'sets_to_win' }.label
  raise "Missing #{language} match-length option" unless label == (language == :pl ? 'Sety do zwycięstwa' : 'Sets to win')
  labels = game.option_definitions.find { |definition| definition.key == 'difficulty' }.choices.map(&:label)
  expected = language == :pl ? ['Bardzo łatwy', 'Łatwy', 'Normalny', 'Trudny', 'Bardzo trudny'] : ['Very easy', 'Easy', 'Normal', 'Hard', 'Very hard']
  raise "Missing #{language} difficulty labels" unless labels == expected
  expected = language == :pl ? 'Na czym polega gra' : 'The game'
  raise "Missing #{language} Audio Ball rulebook" unless game.rule_book.documents.first.text.include?(expected)
  book = game.rule_book.documents.map(&:text).join("\n")
  expected = language == :pl ? 'Przy następnej piłce wybierz obronę nowym naciśnięciem' : "For each incoming ball, press your defence key after the opponent's shot."
  raise "Missing #{language} per-flight defence rules" unless book.include?(expected)
  raise "Unexpected game references in #{language} rules" if book.include?('Axel Pong')
  authored = GameRoomTest::Rulebooks.read('audio_ball', language)
  authored.fetch('sections').each do |section|
    pairs = section.fetch('paragraphs')
    pairs = [section.fetch('title')] + pairs unless section.fetch('id') == 'controls'
    pairs.each do |pair|
      raise "Stale #{language} Audio Ball rules" unless book.include?(pair.fetch(language == :pl ? 'pl' : 'en'))
    end
  end
  expected = language == :pl ? 'Ustawienia odsłuchu' : 'Listening preferences'
  raise "Missing #{language} personal-settings rules" unless book.include?(expected)
  {
    'Audio Ball settings' => 'Ustawienia Audio Ball',
    'Your listening side (only for you)' => 'Twoja strona odsłuchu (tylko dla Ciebie)',
    'Right (default)' => 'Z prawej (domyślnie)',
    'Left' => 'Z lewej',
    'Sound pack (only for you)' => 'Pakiet dźwięków (tylko dla Ciebie)',
    'Sounds from Audiodisc' => 'Dźwięki z audiodisca',
    'Default' => 'Domyślny',
    'Ball stopped after a successful defence' => 'Zatrzymanie piłki po skutecznej obronie'
  }.each do |source, translation|
    expected = language == :pl ? translation : source
    actual = GameRoomLocalization.translate(source.b)
    raise "Missing #{language} settings translation: #{source}" unless actual == expected
  end
  audio.close
end
$rules_dictionary = dictionary
$rules_english = false
GameRoomTestLocalization.use_language(:pl)
puts 'PASS Audio Ball binary speech/rules: Polish, English, missing translation, binary player name and shared Elten speaker'
