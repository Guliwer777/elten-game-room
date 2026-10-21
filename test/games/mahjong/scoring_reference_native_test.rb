require_relative '../../support/rules_native_navigation'
require_relative '../../../games/mahjong_support/mcr_patterns'

%w[en pl cs es ru].each do |language|
  GameRoomTestLocalization.use_language(language)
  game = EltenGameRoom::GAME_REGISTRY.build('mahjong')
  book = game.rule_book(options: game.normalize_options('variant'=>'mcr'))
  document = book.documents.first
  screen = GameRoomScreens::GameRules.new(book)
  form = screen.send(:section_form, document)
  field = form.fields.first
  check_document(field, document, "#{language}/complete Mahjong scoring reference")
  headers = elements(field, EditBox::Element::Header)
  headers.each_cons(2) do |first, second|
    field.index = first.from
    field.press(72)
    assert(field.index == second.from, 'H skipped a scoring heading')
    field.press(72, reverse: true)
    assert(field.index == first.from, 'Shift+H lost a scoring heading')
  end
  text = field.text_range(0, field.text_len - 1)
  assert((1..81).all? { |id| text.include?("MCR #{id}:") }, 'Native view lost an MCR row')
  # Escape closes the actual read-only document and returns to the rules picker.
  parent = GameRoomUI::Form.new([], quiet: true)
  screen.open_on(parent)
  picker = parent.game_room_background_help_form
  picker.accept_button.trigger(:press)
  document_form = parent.game_room_background_help_form
  assert(document_form.fields.first.is_a?(GameRoomRules::View), 'Opened the wrong rules control')
  document_form.cancel_button.trigger(:press)
  assert(parent.game_room_background_help_form.equal?(picker), 'Closing the reference lost its picker')
  parent.clear_game_room_background_help
end
puts "PASS complete Mahjong references in native rules view: five languages, #{$internal_jumps} contents jumps, all headings forward/backward, 81 MCR entries and close/return"
