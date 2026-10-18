require_relative '../support/quiz_creator_native'

Q = GameRoomQuizContributions
program = EltenGameRoom.allocate
views = Q::Views.new(program)

%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  title = 'Żółw; русский; čeština; español'
  cases = [
    ['set', {'title' => nil}, nil],
    ['set', {'title' => ''}, nil],
    ['set', {'title' => title}, title],
    ['question', {'target' => {}}, nil],
    ['question', {'target' => {'title' => nil}}, nil],
    ['question', {'target' => {'title' => ''}}, nil],
    ['question', {'target' => {'title' => title}}, title]
  ]
  cases.each do |kind, fields, expected_title|
    # These are valid incomplete drafts. Model.draft deliberately retains the
    # target reference, including nullable/missing legacy target titles.
    draft = Q::Model.draft(Q::Model.new_draft(kind).merge(fields))
    before = JSON.generate(draft)
    expected = expected_title || GameRoomLocalization.translate('Untitled set')
    Form.driver = lambda do |form|
      list = form.fields.first
      assert(list.is_a?(EltenAPI::Controls::ListBox), 'Menu replaced the native list')
      assert(list.header == expected, "#{language} #{kind}: wrong untitled/title header")
      assert(list.options == ['Add a question', 'Browse questions', 'Add a category', 'Delete draft', 'Send to the author'].map do |label|
        GameRoomLocalization.translate(label)
      end, 'Title presentation changed available actions')
      assert(list.index == 2, 'Title presentation changed focus')
      form.cancel_button.trigger(:press)
    end
    assert(views.set_menu(draft, index: 2) == [:back, 2], 'Cancel changed menu selection')
    assert(JSON.generate(draft) == before, 'Opening the menu changed draft data or target reference')
  end
end
Form.driver = nil
puts "PASS native untitled set menus: #{$assertions} checks across own/existing drafts and five languages"
