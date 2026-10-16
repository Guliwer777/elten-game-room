require_relative '../support/quiz_creator_native'

root = File.expand_path('../..', __dir__)
sources = Dir[File.join(root, 'lib/quiz_contributions/*.rb')] + [File.join(root, 'lib/quiz_reports.rb')]
ids = sources.flat_map do |path|
  File.read(path, encoding: 'UTF-8').scan(/_\(['"]([^'"\n]+)['"]\)/).flatten
end.uniq
program = EltenGameRoom.allocate
%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  catalog = GameRoomLocalization::Catalog.new(File.binread(File.join(root, "locale/#{language.upcase}.mo"))) unless language == 'en'
  ids.each do |id|
    translated = GameRoomLocalization.translate(id.b)
    assert(translated.valid_encoding?, "Invalid encoding in #{language}: #{id}")
    assert(!catalog.translate(id).to_s.empty?, "Missing #{language} contribution translation: #{id}") unless language == 'en'
    assert(translated.scan(/%\{[^}]+\}/).sort == id.scan(/%\{[^}]+\}/).sort, 'Changed interpolation fields')
  end
  Form.driver = lambda do |form|
    form.fields.each_with_index do |field, index|
      form.index = index
      if field.is_a?(EditBox)
        field.focus(nil, nil, false)
      elsif field.respond_to?(:focus)
        field.focus
      end
    end
    form.cancel_button.trigger(:press)
  end
  views = GameRoomQuizContributions::Views.new(program)
  draft = GameRoomQuizContributions::Model.new_draft('set')
  draft['title'] = 'Żółw; русский; čeština; español'
  draft['categories'] = ['Przyroda']
  draft['items'] << GameRoomQuizContributions::Model.new_question('Przyroda').merge('prompt' => draft['title'])
  action, value = views.edit_question(draft, index: 0)
  assert(action == :back && value == draft['items'][0], 'Escape changed question content')
  assert(views.edit_details(draft).nil?, 'Escape accepted set details')
  assert(views.library([]).first == :back, 'Empty library did not cancel')
  assert(views.set_menu(draft).first == :back, 'Set menu did not cancel')
  assert(views.questions(draft).first == :back, 'Question browser did not cancel')
  assert(views.questions(draft.merge('items' => [])).first == :back, 'Empty question browser did not cancel')
  views.notice(GameRoomQuizContributions::Model.completion_errors(draft).join("\r\n"))
  assert(views.draft_label(draft).valid_encoding?, 'Draft label encoding')
  pack_type = Struct.new(:id, :title, :language_id)
  packs = [pack_type.new('one', draft['title'], language)]
  visited_headers = []
  Form.driver = lambda do |form|
    field = form.fields.first
    visited_headers << field.header
    assert(form.fields.size == 3 && form.game_room_program.equal?(program), 'Picker bypassed the shared one-list form')
    field.focus
    assert(field.header.valid_encoding? && field.options.all?(&:valid_encoding?), 'Picker labels have invalid encoding')
    form.accept_button.trigger(:press)
  end
  assert(views.choose_pack(packs).equal?(packs.first), 'Translated picker returned another set')
  assert(visited_headers == ['Language', 'Question set'].map { |label| GameRoomLocalization.translate(label) },
    'Translated picker did not open language and set as separate windows')
end
Form.driver = nil
puts "PASS question contributions in all five languages: #{$assertions} checks"
