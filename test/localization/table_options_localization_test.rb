require_relative "../support/binary_rule_dictionary"

game = GameRoomGames::Domino.new
[true, false].each do |english|
  $rules_english = english
  GameRoomTestLocalization.use_language(english ? :en : :pl)
  defaults = game.default_options
  GameRoomGames::Domino::SETS.each_key do |key|
    definition = game.effective_option_definitions.find { |d| d.key == "tile_set" }
    label = definition.choices.find { |c| c.value == key }.label
    raise "Untranslated domino set in creation form" if !english && label.match?(/Double|tiles|players/)
    raise "Binary domino choice" unless (label + " — поле").valid_encoding?
    text = game.table_options_announcement(defaults.merge("tile_set" => key))
    raise "Choice and announcement disagree" unless text.include?(label)
  end
  text = game.table_options_announcement(defaults)
  raise "Double separators" if text.include?(". .")
  raise "Disabled timers announced" if text.match?(/Thinking time|Czas na ruch|Bot move delay|Opóźnienie bota/)
  text = game.table_options_announcement(defaults.merge("thinking_time" => 20, "bot_delay" => 2))
  expected = english ? "Thinking time: 20 seconds" : "Czas na ruch: 20 sekund"
  raise "Verbose or missing timer: #{text}" unless text.include?(expected)
  raise "Editor instructions announced" if text.match?(/zero|wyłącza|no limit|0–5|0 to 5/)
  raise "Binary announcement" unless (text + " — поле").valid_encoding?
end
puts "PASS compact table options: all 11 Domino sets translated in creation and Ctrl+R, only enabled timers, units, no doubled punctuation; binary EN/PL/native dictionary"

[GameRoomGames::NinetyNine.new, GameRoomGames::Poker.new].each do |game|
  [false, true].each do |english|
    $rules_english = english
    GameRoomTestLocalization.use_language(english ? :en : :pl)
    text = game.table_options_announcement(game.default_options.merge("thinking_time"=>20))
    expected = english ? "Thinking time: 20 seconds" : "Czas na ruch: 20 sekund"
    raise "New timer not localized: #{game.id}" unless text.include?(expected)
    text = game.table_options_announcement(game.default_options)
    raise "Disabled new timer announced" if text.match?(/Thinking time|Czas na ruch/)
    document = game.rule_book(options:game.default_options).documents.first.text
    expected = if game.id == 'ninety_nine'
      english ? 'A turn timer penalises timeout with the loss of one token and the turn.' : 'Włączenie limitu czasu dodaje karę za brak ruchu.'
    else
      english ? 'There is no decision time limit by default.' : 'Domyślnie nie ma limitu czasu na decyzję.'
    end
    raise "Timer unexpectedly enabled by default" unless game.default_options.fetch('thinking_time').zero?
    raise "Missing timer rules: #{game.id}" unless document.include?(expected)
    raise "Bad timer rule encoding" unless (document + " — поле").valid_encoding?
    next unless game.id == "ninety_nine"
    entry = GameRoomGames::HistoryEntry.new(key:"timeout:1", text:"unused", event_id:1, actor:"A", kind: :timeout_penalty)
    replay = GameRoomGames::Replay.new(history:[entry])
    message = game.history_entries_for_display(replay,"A").first.text
    expected = english ? "You lose 1 token for running out of time." : "Tracisz 1 żeton za przekroczenie czasu."
    raise "Wrong local timeout message" unless message == expected && (message + " — поле").valid_encoding?
  end
end
puts "PASS 99/Poker: concise enabled timer only, translated rules and exact personal timeout message under binary/native dictionary"
