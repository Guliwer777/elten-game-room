require_relative '../support/quiz_contributions'
include QuestionContributionTest
Q = GameRoomQuizContributions

Dir.mktmpdir('question-creator-') do |directory|
  user = 'guest'
  storage = QuestionContributionTest::Storage.new(directory)
  drafts = Q::Drafts.new(storage, user: user, current_user: -> { user })
  files = QuestionContributionTest::Files.new
  repo = Q::Repository.new(app_uuid: 'test', user: user, current_user: -> { user }, client: Object.new, api: files)
  value = drafts.save(sample)
  packet = Q::Model.packet(value, author: user)
  assert(packet['proposal']['items'][0]['correct_index'] == 2, 'Correct choice moved')
  assert(packet['proposal']['description'] == '', 'Optional description became mandatory')
  assert(packet['proposal']['items'][0]['source'] == '', 'Optional source became mandatory')
  empty = Q::Model.new_draft('set')
  drafts.save(empty)
  rejects { Q::Model.packet(empty, author: user) }
  duplicate = Q::Model.copy(value)
  duplicate['items'][0]['choices'][1] = ' DĄB '
  assert(Q::Model.packet(duplicate, author: user)['proposal']['items'][0]['choices'][1] == 'DĄB', 'Repeated answers were rejected')
  duplicate = Q::Model.copy(value)
  duplicate['items'] *= 2
  assert(Q::Model.packet(duplicate, author: user)['proposal']['items'].size == 2, 'Repeated questions were rejected')
  partial = Q::Model.copy(value)
  partial['title'] = ''
  partial['items'] << Q::Model.new_question
  errors = Q::Model.completion_errors(partial)
  assert(errors.include?('Set: enter a title.'), 'Missing set title not explained')
  assert(errors.include?('Question 2: Enter the question.'), 'Missing question not numbered')
  %w[A B C D].each { |letter| assert(errors.include?("Question 2: Enter answer #{letter}."), 'Missing answer not identified') }
  assert(errors.include?('Question 2: Choose a category.'), 'Missing category not identified')
  malformed = Q::Model.copy(value)
  malformed['items'][0]['correct_index'] = 4
  rejects { Q::Model.draft(malformed) }
  huge = Q::Model.copy(value)
  huge['items'] *= 1001
  rejects { Q::Model.draft(huge) }
  # A 1000-question set is one private file and one attachment, not 1000 rows.
  large = Q::Model.copy(value)
  large['items'] = 1000.times.map { |i| value['items'][0].merge('prompt' => "Test #{i}: Żółw, čeština, русский, español?") }
  large = drafts.save(large)
  cloud = repo.save(large)
  assert(files.rows.size == 1 && repo.read(cloud)['items'].size == 1000, 'Large draft did not round trip')
  assert(Q::Model.packet(large, author: user)['submission_id'] == Q::Model.packet(cloud, author: user)['submission_id'], 'Cloud transport changed submission identity')

  # Saving after opening on another computer replaces only its own baseline.
  copy = repo.read(repo.list.first)
  copy['items'][0]['note'] = 'Second computer'
  copy = drafts.save(copy)
  cloud2 = repo.save(copy)
  assert(files.rows.size == 1 && files.rows.first.id == cloud2['resource_id'], 'Successful save left old snapshot')
  # Lost upload acknowledgement: retry same operation, no second upload.
  copy['items'][1]['note'] = 'Lost reply'
  copy = drafts.save(copy.merge('resource_id' => cloud2['resource_id'], 'resource_name' => cloud2['resource_name']))
  files.fail = [:upload, true]
  rejects(IOError) { repo.save(copy) }
  assert(files.rows.size == 2, 'Failed save deleted older snapshot')
  cloud3 = repo.save(copy)
  assert(files.rows.size == 1, 'Retry duplicated upload or left old snapshot')
  # Failed delete, failed download and full/offline store keep the draft editable.
  copy = drafts.save(cloud3.merge('description' => 'Changed'))
  files.fail = [:delete, false]
  rejects(IOError) { repo.save(copy) }
  assert(files.rows.size == 2, 'Delete failure destroyed data')
  cloud4 = repo.save(copy)
  assert(files.rows.size == 1, 'Delete retry did not converge')
  copy = drafts.save(cloud4.merge('description' => 'Changed again'))
  files.fail = [:upload, false]
  rejects(IOError) { repo.save(copy) }
  assert(repo.read(cloud4)['description'] == 'Changed', 'Unconfirmed write changed baseline')
  copy = drafts.save(copy.merge('description' => 'Editable after failure'))
  assert(copy['description'] == 'Editable after failure', 'Failed submission locked editor')
  cloud5 = repo.save(copy)
  # Concurrent clients save separate copies rather than silently drop edits.
  a, b = repo.read(cloud5), repo.read(cloud5)
  a = drafts.save(a.merge('description' => 'A'))
  repo.save(a)
  b = drafts.save(b.merge('description' => 'B'))
  repo.save(b)
  assert(repo.list.size == 2, 'Concurrent branch was silently overwritten')
  # Unrelated resources are untouched and another account cannot read drafts.
  files.rows << QuestionContributionTest::Resource.new(id: 5000, resource: 'game-save-existing', uploader: user)
  assert(repo.list.size == 2, 'Unrelated saved game treated as quiz draft')
  user = 'other'
  rejects(Q::Unavailable) { repo.list }
  rejects(Q::Unavailable) { drafts.list }
  user = 'guest'
  files.user = 'other'
  assert(repo.list.empty?, 'Private resources leaked across accounts')
  files.user = 'guest'
  files.after_call = ->(op) { user = 'other' if op == :list }
  rejects(Q::Unavailable) { repo.save(copy) }
  files.after_call = nil
  user = 'guest'

  mailbox = QuestionContributionTest::Mailbox.new
  delivery = Q::Delivery.new(repo, messages: mailbox)
  packet = Q::Model.packet(sample, author: user)
  mailbox.fail = :before
  rejects(IOError) { delivery.send(packet) }
  assert(mailbox.rows.empty?, 'Failure before send produced a message')
  mailbox.fail = :after
  rejects(IOError) { delivery.send(packet) }
  assert(mailbox.rows.size == 1, 'Lost acknowledgement was not simulated')
  assert(delivery.send(packet), 'Retry did not reconcile')
  assert(mailbox.rows.size == 1, 'Retry duplicated message')
  assert(mailbox.paths.none? { |p| File.exist?(p) }, 'Temporary ZIP was not removed')
  payload = mailbox.rows.first.payload
  assert(payload.keys.sort == %w[questions.json questions.txt], 'Attachment formats missing')
  assert(JSON.parse(payload['questions.json']) == packet, 'JSON export changed answers')
  assert(payload['questions.txt'].force_encoding('UTF-8').include?('C. Sosna'), 'Readable ABCD content changed')
  assert(payload['questions.txt'].include?('Correct answer: C'), 'Readable answer key wrong')
  mailbox.fail = :read
  rejects(IOError) { delivery.send(packet) }
  assert(mailbox.rows.size == 1, 'Uncertain status allowed another send')
  mailbox.fail = nil
  mailbox.rows.first.sender = 'forged'
  assert(!delivery.delivered?(packet), 'Wrong sender accepted as delivery')
  mailbox.rows.first.sender = 'guest'
  mailbox.rows.first.attachments_names = ['wrong.zip']
  assert(!delivery.delivered?(packet), 'Wrong attachment accepted')
  mailbox.more = true
  rejects(Q::Unavailable) { delivery.delivered?(packet) }
  mailbox.more = false
  mailbox.rows.first.attachments_names = [delivery.filename(packet)]
  key = packet['submission_id']
  files.fail = [:upload, true]
  rejects(IOError) { repo.record_delivery(key) }
  assert(repo.record_delivery(key), 'Lost receipt acknowledgement did not reconcile')
  assert(files.rows.count { |r| r.resource.start_with?(Q::Repository::RECEIPT_PREFIX) } == 1, 'Receipt retry uploaded twice')
  assert(repo.list.size == 2, 'Delivery receipt appeared as a set')
  mailbox.fail = :delete
  rejects(IOError) { delivery.remove_sender_copy(packet) }
  assert(repo.delivered?(key) && mailbox.deleted.empty?, 'Failed message cleanup lost evidence')
  mailbox.fail = nil
  delivery.remove_sender_copy(packet)
  assert(mailbox.deleted == [mailbox.rows.first.id], 'Sender copy was not removed')
  assert(!delivery.delivered?(packet), 'Sender copy remains listed')
  other_pc = Q::Repository.new(app_uuid: 'test', user: user, current_user: -> { user }, client: Object.new, api: files)
  assert(other_pc.delivered?(key), 'Another computer lost evidence after message deletion')
  assert(mailbox.rows.first.payload == payload, 'Recipient payload was removed')
  self_repo = Q::Repository.new(app_uuid: 'test', user: 'papierek', current_user: -> { 'papierek' }, client: Object.new, api: files)
  assert(Q::Delivery.new(self_repo, messages: mailbox).remove_sender_copy(packet), 'Self-addressed exception failed')
  assert(mailbox.deleted.size == 1, 'Self-addressed submission was deleted')

  # Content validation is independent of the form and fails before upload.
  encoded = files.rows.find { |r| r.resource.start_with?(Q::Repository::PREFIX) }
  ref = repo.list.first
  encoded.data = 'invalid'
  rejects { repo.read(ref) }
  # Corrupt recovery must not be overwritten, even though host read_json uses defaults.
  File.write(storage.data_path(Q::Drafts::FILE), '{broken')
  rejects { drafts.list }
  assert(File.read(storage.data_path(Q::Drafts::FILE)) == '{broken', 'Corrupt drafts overwritten')
end
puts "PASS question creator model, files and delivery: #{@checks} checks"
