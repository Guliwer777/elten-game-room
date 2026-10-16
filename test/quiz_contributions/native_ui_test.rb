require_relative '../support/quiz_creator_native'
require_relative '../support/quiz_contributions'

NativeOptionTest.language = 'en'
module Session
  def self.name; 'guest'; end
end
Q = GameRoomQuizContributions
program = EltenGameRoom.allocate
steps = []
Form.driver = lambda do |form|
  assert(form.game_room_program.equal?(program), 'Lost program-owned form')
  if form.fields.first.is_a?(ListBox) && form.fields.first.options.first == 'Add a question'
    assert(form.fields.first.options == ['Add a question', 'Browse questions', 'Add a category', 'Delete draft', 'Send to the author'], 'Set menu order or question separation changed')
  end
  step = steps.shift or raise "Unexpected form #{form.fields.map(&:header).inspect}"
  step.call(form)
end
pick = ->(i) { ->(form) { form.fields.first.index = i; form.accept_button.trigger(:press) } }
cancel = ->(form) { form.cancel_button.trigger(:press) }
new_set = lambda do |form|
  visible = form.fields.each_with_index.reject { |_, i| form.instance_variable_get(:@hidden)[i] }
  assert(visible.size == 1, 'Library exposes Open/Cancel buttons')
  menu = Menu.new
  form.fields.first.context(menu, false)
  menu.items.find { |item| item[3] == 'n' }.fetch(1).call
end
notice = lambda do |*expected|
  lambda do |form|
    assert(form.fields.first.is_a?(GameRoomUI::HelpText), 'Error is not a persistent read-only dialog')
    expected.each { |message| assert(form.fields.first.text.include?(message), "Missing notice: #{message}") }
    form.accept_button.trigger(:press)
  end
end
fill = lambda do |values|
  lambda do |form|
    assert(form.accept_button.nil?, 'Enter submits a multiline text field')
    values.each do |label, value|
      field = form.fields.find { |f| f.header == label } or raise "Missing field #{label}"
      field.is_a?(ListBox) ? field.index = value : field.set_text(value)
    end
    if form.fields.first.header == 'Question'
      assert(form.fields[5].is_a?(ListBox), 'Category is not a selector')
    end
    visible = form.fields.each_with_index.select { |f, i| f.is_a?(Button) && !form.instance_variable_get(:@hidden)[i] }.map { |f, _| f.label }
    assert(visible == ['Save'], 'Editor has unexpected buttons')
    form.fields.find { |field| field.is_a?(Button) && field.label == 'Save' }.trigger(:press)
  end
end
question = {'Question' => 'Które z tych drzew ma igły?', 'Correct answer (A)' => 'Sosna', 'Answer B' => 'Dąb',
  'Answer C' => 'Buk', 'Answer D' => 'Klon', 'Category' => 0}

Dir.mktmpdir('question-ui-') do |dir|
  storage = QuestionContributionTest::Storage.new(dir)
  drafts = Q::Drafts.new(storage, user: 'guest', current_user: -> { Session.name })
  files = QuestionContributionTest::Files.new
  repo = Q::Repository.new(app_uuid: 'test', user: 'guest', current_user: -> { Session.name }, client: Object.new, api: files)
  mailbox = QuestionContributionTest::Mailbox.new
  controller = Q::Controller.new(program, drafts: drafts, repository: repo, delivery: Q::Delivery.new(repo, messages: mailbox))
  controller.define_singleton_method(:task) do |_title, quiet: false, failure: nil, &job|
    job.call(nil)
  rescue Q::Error, IOError => error
    @views.notice(failure || error.message)
    nil
  end
  # Empty library -> Ctrl+N -> Save -> listed empty set -> category -> question.
  steps.concat([new_set, pick.call(0), fill.call({'Set title' => 'Drzewa', 'Language code (for example pl or en)' => 'pl'}),
    ->(form) {
      assert(repo.list.size == 1 && repo.read(repo.list.first)['items'].empty?, 'New empty set not saved before returning to library')
      pick.call(0).call(form)
    },
    pick.call(0), notice.call('at least one category'),
    pick.call(1), ->(form) { assert(form.fields.first.options == ['Press Ctrl+N to add a question.'], 'Empty question list is unclear'); cancel.call(form) },
    pick.call(2), fill.call({'Category name' => 'Przyroda'}),
    pick.call(0), fill.call(question),
    pick.call(4), pick.call(1), notice.call('Sent to the author.'), cancel])
  controller.creator
  assert(steps.empty? && mailbox.rows.size == 1, 'One-question send failed')
  assert(repo.list.empty? && drafts.list.empty?, 'Confirmed delivery left draft')
  assert(mailbox.deleted == [1], 'Sender message remains')
  assert(JSON.parse(mailbox.rows.first.payload['questions.json'])['proposal']['items'].size == 1, 'One-question send count wrong')

  # Existing-set proposal; incomplete fields are saved, each missing answer is named.
  steps.concat([new_set, pick.call(1), ->(form) {
    assert(form.fields.size == 3 && form.fields.first.header == 'Language', 'Language must open in its own window')
    form.accept_button.trigger(:press)
  }, ->(form) {
    assert(form.fields.size == 3 && form.fields.first.header == 'Question set', 'Set must open after language in a separate window')
    form.accept_button.trigger(:press)
  }, pick.call(0),
    pick.call(0), fill.call({'Question' => 'Nieukończone pytanie'}),
    pick.call(4), notice.call(*%w[A B C D].map { |letter| "Question 1: Enter answer #{letter}." }),
    pick.call(1), pick.call(0), fill.call(question), cancel,
    pick.call(4), pick.call(1), notice.call('Sent to the author.'), cancel])
  controller.creator
  assert(steps.empty? && mailbox.rows.size == 2 && repo.list.empty?, 'Resume and send after detailed validation failed')

  # Failed cloud save returns to the library as local recovery, editable on retry.
  files.fail = [:upload, false]
  steps.concat([new_set, pick.call(0), fill.call({'Set title' => 'Retry', 'Language code (for example pl or en)' => 'pl'}),
    notice.call('saved only on this computer'),
    ->(form) {
      assert(drafts.list.size == 1 && repo.list.empty?, 'Failed save lost local recovery')
      pick.call(0).call(form)
    },
    pick.call(2), fill.call({'Category name' => 'General'}),
    pick.call(0), fill.call(question), cancel, cancel])
  controller.creator
  assert(steps.empty? && drafts.list.empty? && repo.list.size == 1, 'Retry did not save account draft')
  assert(repo.read(repo.list.first)['items'].size == 1, 'Question was not saved')

  # Cleanup failure keeps the confirmed draft. Retrying does not send it twice.
  mailbox.fail = :delete
  steps.concat([pick.call(0), pick.call(4), pick.call(1), notice.call('questions were sent'), cancel])
  controller.creator
  assert(steps.empty? && mailbox.rows.size == 3 && repo.list.size == 1, 'Cleanup failure lost sent draft')
  mailbox.fail = nil
  steps.concat([pick.call(0), pick.call(4), pick.call(1), notice.call('Sent to the author.'), cancel])
  controller.creator
  assert(steps.empty? && mailbox.rows.size == 3 && repo.list.empty?, 'Cleanup retry duplicated submission')

  # New question can be discarded without persisting a blank item.
  draft = Q::Model.new_draft('set').merge('title' => 'Cancel', 'language' => 'pl', 'categories' => ['General'])
  steps.concat([pick.call(0), cancel, cancel])
  controller.edit(draft)
  assert(steps.empty? && draft['items'].empty?, 'Cancelled question was added')

  # A changed question asks before discarding; returning keeps typed text.
  steps.concat([pick.call(0),
    ->(form) { form.fields.first.set_text('Working text'); cancel.call(form) },
    pick.call(1),
    ->(form) {
      assert(form.fields.first.text == 'Working text', 'Continue editing lost typed text')
      fill.call(question).call(form)
    }, cancel])
  controller.edit(draft)
  assert(steps.empty? && repo.list.size == 1, 'Continue editing did not save')

  # Add a category from the question without rebuilding or losing typed fields.
  draft = repo.read(repo.list.first)
  steps.concat([pick.call(0),
    ->(form) {
      fields = form.fields.dup
      fields[0].set_text('Question kept while adding a category')
      fields[1, 4].each_with_index { |field, i| field.set_text("Answer #{i}") }
      fields[6].set_text('Optional source kept')
      fields[7].set_text('Optional note kept')
      category = fields[5]
      assert(category.options.last == 'Add a new category', 'Missing inline category action')
      category.index = category.options.size - 1
      category.trigger(:select)
      assert(form.fields == fields && fields[0].text == 'Question kept while adding a category', 'Adding a category rebuilt or cleared the question')
      assert(category.options[category.index] == 'Inline category', 'New category not selected')
      assert(repo.list.size == 1 && repo.read(repo.list.first)['items'].size == 1, 'Adding a category saved the pending question or left old snapshots')
      # A duplicate name selects the existing category; cancelling keeps it.
      category.index = category.options.size - 1
      category.trigger(:select)
      assert(category.options.count('Inline category') == 1, 'Duplicate category appeared twice')
      category.index = category.options.size - 1
      category.trigger(:select)
      assert(category.options[category.index] == 'Inline category', 'Cancelling category lost previous selection')
      fill.call({}).call(form)
    },
    fill.call({'Category name' => 'Inline category'}),
    fill.call({'Category name' => 'Inline category'}), cancel,
    pick.call(1), pick.call(1),
    ->(form) {
      assert(form.fields[0].text == 'Question kept while adding a category', 'Question missing from separate browser')
      assert(form.fields[5].options[form.fields[5].index] == 'Inline category', 'Question category not persisted')
      assert(form.fields[6].text == 'Optional source kept' && form.fields[7].text == 'Optional note kept', 'Inline category lost optional fields')
      cancel.call(form)
    }, cancel, cancel])
  controller.edit(draft)
  assert(steps.empty? && repo.list.size == 1, 'Inline category/question left stale server snapshot')
  updated = repo.read(repo.list.first)
  assert(updated['items'].size == 2 && updated['items'][1]['correct_index'] == 0, 'Question content or correct answer changed')

  # The action row is not itself a category, even if Tab moves away from it.
  steps << ->(form) {
    form.fields[5].index = form.fields[5].options.size - 1
    fill.call({}).call(form)
  }
  action, value = Q::Views.new(program).edit_question(updated, index: 1)
  assert(action == :save && value['category'] == 'Inline category', 'Action label became question category')

  # Legacy drafts may mark B, C or D as correct. Merely opening and cancelling
  # the editor must not alter storage or prompt to save a cosmetic reorder.
  legacy = Q::Model.copy(updated)
  legacy['items'][0]['correct_index'] = 3
  updated = controller.send(:persist, legacy)
  original = Q::Model.copy(repo.read(repo.list.first))
  correct = original['items'][0]['choices'][3]
  steps.concat([pick.call(1), pick.call(0), ->(form) {
    assert(form.fields[1].header == 'Correct answer (A)' && form.fields[1].text == correct, 'Legacy correct answer was not moved to A')
    assert(!form.fields.any? { |f| f.is_a?(ListBox) && f.header == 'Correct answer' }, 'Old correct-answer selector remains')
    cancel.call(form)
  }, cancel, cancel])
  controller.edit(updated)
  assert(steps.empty? && repo.read(repo.list.first) == original, 'Cancelling changed a legacy draft')
  steps.concat([pick.call(1), pick.call(0), fill.call({}), cancel, cancel])
  controller.edit(updated)
  updated = repo.read(repo.list.first)
  assert(steps.empty? && updated['items'][0]['correct_index'] == 0, 'Saving a legacy draft did not normalize the index')
  assert(updated['items'][0]['choices'][0] == correct, 'Saving changed which answer is correct')

  # Declining or failing deletion keeps the menu and draft; success removes only it.
  other = controller.send(:persist, Q::Model.new_draft('set').merge('title' => 'Unrelated', 'language' => 'en'))
  files.fail = [:delete, false]
  steps.concat([pick.call(3), pick.call(0), pick.call(3), pick.call(1), notice.call('network interrupted'),
    pick.call(3), pick.call(1)])
  controller.edit(updated)
  assert(steps.empty? && repo.list.map { |ref| ref['id'] } == [other['id']], 'Delete draft removed unrelated data or left current draft')
end
Form.driver = nil
puts "PASS question creator native controls: #{$assertions} checks"
