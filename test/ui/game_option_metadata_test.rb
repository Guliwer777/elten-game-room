require_relative '../support/game_option_encoding'

GameRoomTestLocalization.use_language('en')
app = EltenGameRoom.allocate
app.define_singleton_method(:read_json) { |_path, default:| default }
app.define_singleton_method(:remember_multiple_choice_options) { |*_arguments| }
app.define_singleton_method(:alert) { |message| raise message }

submit = lambda do |game, initial = nil, &change|
  Form.option_encoding_driver = lambda do |form|
    change&.call(form)
    form.accept_button.trigger(:press)
  end
  app.send(:configure_game_options, game, initial_options: initial)
end
check = ->(value, message) { raise message unless value }

categories = GameRoomGames::Categories.new
fresh = categories.table_creation_options('category_set' => 'custom',
  'custom_categories' => %w[drink known_writer], 'round_category_count' => 2)
check.call(submit.call(categories) == categories.table_creation_options, 'Creation lost canonical metadata')
check.call(submit.call(categories, fresh) == fresh, 'Editing changed the new category dialect')
legacy = categories.normalize_options('category_set' => 'custom',
  'custom_categories' => 1 << 9, 'round_category_count' => 1)
check.call(submit.call(categories, legacy) == legacy, 'Editing rewrote historical options')
check.call(categories.send(:selected_category_pool, legacy) == ['surname'], 'Legacy mask was reinterpreted')

changed = submit.call(categories, fresh) do |form|
  definition = categories.effective_option_definitions(fresh).find { |item| item.key == 'custom_categories' }
  control = form.fields.grep(ListBox).find { |item| item.header == definition.label }
  control.deselect_multiselection_indices(control.multiselections)
  control.select_multiselection_indices(definition.choices.each_index.select { |index| %w[tool drink].include?(definition.choices[index].value) })
end
check.call(changed['category_version'] == 2, 'Changing a visible field dropped the category dialect')
check.call(categories.send(:selected_category_pool, changed).sort == %w[drink tool], 'New custom mask used legacy choices')
check.call(fresh == categories.table_creation_options('category_set' => 'custom',
  'custom_categories' => %w[drink known_writer], 'round_category_count' => 2), 'The initial options were mutated')

miles = GameRoomGames::MilleBornes.new
initial = miles.normalize_options(GameRoomTeams::OPTION_KEY => [0, 1, 0, 1],
  GameRoomTeams::PLAYERS_KEY => %w[A B C D], 'team_size' => 2)
check.call(submit.call(miles, initial.merge('unknown_option' => 'discard')) == initial,
  'Canonical team metadata was lost or undeclared input was retained')

quiz = GameRoomGames::QuizParty.new
initial = quiz.table_creation_options('content_language_id' => 'pl-PL', 'content_set_id' => 'quiz.wikidata')
changed = submit.call(quiz, initial) do |form|
  definition = quiz.effective_option_definitions(initial).find { |item| item.key == 'content_language_id' }
  control = form.fields.grep(ListBox).find { |item| item.header == definition.label }
  control.index = definition.choices.index { |choice| choice.value == 'en' }
  control.trigger(:move)
end
check.call(changed['content_language_id'] == 'en' && changed['content_set_id'] == 'quiz.general',
  'Dependent content controls retained the previous language')
check.call(quiz.validation_error(changed).nil? && quiz.selected_content_pack(changed)&.language_id == 'en',
  'Preserving metadata retained a stale content-pack identity')
check.call(initial['content_language_id'] == 'pl-PL', 'Language editing mutated the source options')

puts 'PASS option metadata: new/legacy category masks, edits, teams, unknown keys and dependent content packs; no keyboard or network'
