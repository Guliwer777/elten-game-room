require_relative '../support/quiz_creator_native'
require_relative '../support/quiz_contributions'

NativeOptionTest.language = 'en'
Object.const_set(:Session, EltenAPI::Structs::Session)
Session.name = 'guest'
Q = GameRoomQuizContributions
program = EltenGameRoom.allocate
steps = []
Form.driver = lambda do |form|
  step = steps.shift or raise "Unexpected recovery form #{form.fields.map(&:header).inspect}"
  step.call(form)
end
cancel = ->(form) { form.cancel_button.trigger(:press) }
pick = ->(index) { ->(form) { form.fields.first.index = index; form.accept_button.trigger(:press) } }

Dir.mktmpdir('quiz-null-ui-') do |directory|
  storage = QuestionContributionTest::Storage.new(directory)
  drafts = Q::Drafts.new(storage, user: 'guest', current_user: -> { 'guest' })
  original = QuestionContributionTest.sample
  original['snapshot'] = SecureRandom.uuid
  original['resource_id'] = 37
  original['resource_name'] = 'original snapshot'
  original['opaque'] = {'nullable' => nil, 'keep' => ['  untouched  ']}
  original['title'] = '  Untrimmed title  '
  original['categories'] = ['Category', 'Category']
  original['items'][0]['correct_index'] = 3
  original['items'][0]['source'] = nil
  original['items'][0]['note'] = nil
  complete_digest = Q::Model.packet(original, author: 'guest')['submission_id']
  incomplete = Q::Model.new_draft('set')
  incomplete.merge!('title' => nil, 'language' => nil, 'description' => nil)
  incomplete['items'] = [Q::Model.new_question.merge('prompt' => nil, 'category' => nil,
    'source' => nil, 'note' => nil, 'choices' => [nil, '  retained  ', nil, ''], 'correct_index' => 2)]
  root = {'version' => 1, 'accounts' => {'guest' => {'drafts' => {
    original['id'] => original, incomplete['id'] => incomplete}, 'delivered' => []}}}
  File.binwrite(storage.data_path(Q::Drafts::FILE), JSON.generate(root))
  listed = drafts.list
  assert(Q::Model.packet(listed[0], author: 'guest')['submission_id'] == complete_digest,
    'Recovery changed a submitted packet identity')
  assert(listed[0]['opaque'] == original['opaque'] && listed[0]['title'] == original['title'] &&
    listed[0]['categories'] == original['categories'], 'Recovery normalized unrelated values')
  assert(listed[0]['snapshot'] == original['snapshot'] && listed[0]['resource_id'] == 37 &&
    listed[0]['resource_name'] == original['resource_name'], 'Recovery changed delivery metadata')
  assert(listed[0]['items'][0]['correct_index'] == 3 && listed[1]['items'][0]['correct_index'] == 2,
    'Read-only recovery moved the correct answer')
  assert(Q::Model.categories(listed[1]).empty?, 'Null category became a fake category')
  assert(Q::Model.completion_errors(listed[1]).include?('Question 1: Enter answer A.'),
    'Nullable recovery bypassed required-field validation')
  assert(JSON.parse(File.binread(storage.data_path(Q::Drafts::FILE))) == root,
    'Listing persisted the editor projection')

  files = QuestionContributionTest::Files.new
  repository = Q::Repository.new(app_uuid: 'test', user: 'guest', current_user: -> { 'guest' }, client: Object.new, api: files)
  delivery = Q::Delivery.new(repository, messages: QuestionContributionTest::Mailbox.new)
  controller = Q::Controller.new(program, drafts: drafts, repository: repository, delivery: delivery)
  controller.define_singleton_method(:task) { |_title, **_options, &job| job.call(nil) }
  # Both the list and actual editor must accept empty fields. Cancel must not
  # create a misleading Save/Continue/Discard dialog for nil-to-empty display.
  steps.concat([->(form) {
    assert(form.fields.first.header == 'Untitled set', 'Recovered untitled set opened an unnamed menu')
    pick.call(1).call(form)
  }, ->(form) {
    assert(form.fields.first.options == ['1. Untitled question'], 'Blank prompt was not presented safely')
    pick.call(0).call(form)
  }, ->(form) {
    assert(form.fields[0].text.empty? && form.fields[1].text.empty? && form.fields[2].text.empty?,
      'Null fields were not rendered as blank edits')
    assert(form.fields[3].text == '  retained  ', 'Recovery or editor reordered or trimmed the wrong answer')
    cancel.call(form)
  }, cancel, cancel])
  controller.edit(listed[1])
  assert(steps.empty? && files.calls.empty?, 'Cancelling recovered fields unexpectedly saved or contacted the account store')
  assert(JSON.parse(File.binread(storage.data_path(Q::Drafts::FILE))) == root,
    'Opening and cancelling changed recovery data')

  # Optional nulls are also blank in a complete legacy question; editing alone
  # keeps D correct and never reissues a proposal under a new content digest.
  steps.concat([pick.call(1), pick.call(0), ->(form) {
    assert(form.fields[1].text == original['items'][0]['choices'][3], 'Legacy D was not displayed as the correct editor answer')
    assert(form.fields[6].text.empty? && form.fields[7].text.empty?, 'Optional nulls were not blank')
    cancel.call(form)
  }, cancel, cancel])
  controller.edit(listed[0])
  assert(steps.empty? && files.calls.empty?, 'Legacy null display prompted or saved without edits')
  assert(Q::Model.packet(drafts.list[0], author: 'guest')['submission_id'] == complete_digest,
    'Cancelled legacy editor changed the delivery digest')
end
Form.driver = nil
puts "PASS nullable recovery native creator UI: #{$assertions} checks"
