require_relative '../../support/host_source'
require_relative '../../support/game_room_language_runtime'
require_relative '../../support/assertions'

include GameRoomTest::Assertions
GameRoomLanguageRuntime.load_host(EltenTestHost.root)
root = GameRoomLanguageRuntime::ROOT
catalogs = %w[pl cs es ru].to_h { |code| [code, File.binread(File.join(root, "locale/#{code.upcase}.mo"))] }
expected = {'en' => ['Correct!', 'Wrong!'], 'pl' => ['Dobrze!', 'Źle!'],
  'cs' => ['Správně!', 'Špatně!'], 'es' => ['¡Bien!', '¡Mal!'], 'ru' => ['Верно!', 'Неверно!']}
ready = {
  'en' => 'Use the digits from 1 through 0 to reveal sounds. Reveal two on your turn and try to find a matching pair. Press Enter when you are ready.',
  'pl' => 'Cyframi od 1 do 0 odkrywasz dźwięki. W swojej turze odkryj dwa i spróbuj znaleźć parę. Naciśnij Enter, gdy zechcesz zacząć.',
  'cs' => 'Číslicemi od 1 po 0 odkrývejte zvuky. Ve svém tahu odkryjte dva a zkuste najít dvojici. Až budete připraveni, stiskněte Enter.',
  'es' => 'Usa las teclas del 1 al 0 para descubrir los sonidos. En tu turno, descubre dos e intenta encontrar una pareja. Pulsa Enter cuando quieras empezar.',
  'ru' => 'Открывайте звуки клавишами от 1 до 0. В свой ход откройте два звука и попробуйте найти пару. Когда будете готовы, нажмите Enter.'
}

GameRoomLanguageRuntime.protect_host do
  expected.each do |code, words|
    runtime = GameRoomLanguageRuntime::Runtime.new(settings: {'interface_language' => code}, catalogs: catalogs).start
    Programs.with_runtime(runtime) do
      runtime.require_file(File.join(root, 'games/duck_racing_support/challenge_presentation.rb'))
    end
    assert_equal([Encoding::ASCII_8BIT], runtime.source_encodings.uniq)
    presenter = runtime.namespace::GameRoomDuckRacing::ChallengePresentation
    practice = presenter.project(kind: 'sound_memory', viewer: 0,
      view: {type: 'sound_memory', seats: [0, 1], practice: true, own: {ready: false}})
    assert_equal(ready.fetch(code), practice[:announcement])
    assert_equal(practice[:announcement], presenter.reminder('sound_memory',
      {type: 'sound_memory', seats: [0, 1], practice: true, own: {ready: false}}))
    assert_equal(presenter.description('sound_memory')[1],
      presenter.reminder('sound_memory', {type: 'sound_memory', own: {}}))
    assert(practice[:announcement].encoding == Encoding::UTF_8 && practice[:announcement].valid_encoding?)
    event = {seat: 0, position: 0}
    initial = presenter.memory_feedback(event, ['Gęś'.b])
    assert_equal({announcement: 'Gęś: 0.'}, initial)
    [true, false].each_with_index do |matched, index|
      message = presenter.memory_feedback(event.merge(matched: matched), ['Gęś'.b])
      assert_equal('Gęś: 0.', message[:announcement])
      assert_equal(words[index], message[:result_announcement])
      message.each_value { |text| assert(text.encoding == Encoding::UTF_8 && text.valid_encoding?) }
    end
  end
end
puts 'PASS memory feedback translations: five native binary-loaded language runtimes and Unicode names'
