require_relative '../../support/rules_native_navigation'

names = {'en'=>'Bridge', 'pl'=>'Brydż', 'cs'=>'Bridž', 'es'=>'Bridge', 'ru'=>'Бридж'}
names.each do |language, name|
  GameRoomTestLocalization.use_language(language)
  game = EltenGameRoom::GAME_REGISTRY.build('bridge')
  assert(GameRoomContent.utf8(game.name) == name, "#{language}: missing game name")
  book = game.rule_book(options: game.default_options)
  assert(book.documents.first.sections.map(&:id) == [:aim, :deal, :auction, :play, :scoring, :bonuses, :honors, :variants, :bots],
    "#{language}: incomplete Bridge rulebook")
  screen = GameRoomScreens::GameRules.new(book, game_shortcuts: ['D: Dummy'])
  screen.instance_variable_get(:@documents).each do |document|
    form = screen.send(:section_form, document)
    if document.id == :controls
      assert(form.fields.first.options == ['D: Dummy'], "#{language}: live shortcuts were lost")
    else
      check_document(form.fields.first, document, "#{language}/bridge/#{document.id}")
    end
  end
end
puts "PASS Bridge binary source/native rules: five complete editions, #{$internal_jumps} contents jumps, #{$assertions} checks"
