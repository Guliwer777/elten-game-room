require_relative '../support/quiz_contributions'
include QuestionContributionTest
Q = GameRoomQuizContributions

# The host's JSON reader accepts syntactically valid but damaged nested data.
# Reject it before handing a row to the native library/editor, and do not
# rewrite the recovery file while detecting damage.
Dir.mktmpdir('creator-local-boundary-') do |directory|
  storage = QuestionContributionTest::Storage.new(directory)
  drafts = Q::Drafts.new(storage, user: 'guest', current_user: -> { 'guest' })
  original = sample
  malformed = [nil, [], 'not a draft', original.merge('items' => nil),
    original.merge('items' => [nil]), original.merge('categories' => [nil])]
  malformed.each do |value|
    root = {'version' => 1, 'accounts' => {'guest' => {'drafts' => {original['id'] => value}, 'delivered' => []}}}
    bytes = JSON.pretty_generate(root) + "\n"
    File.binwrite(storage.data_path(Q::Drafts::FILE), bytes)
    rejects { drafts.list }
    assert(File.binread(storage.data_path(Q::Drafts::FILE)) == bytes.b,
      'A malformed local draft was silently rewritten')
  end
  different_key = SecureRandom.uuid
  root = {'version' => 1, 'accounts' => {'guest' => {'drafts' => {different_key => original}, 'delivered' => []}}}
  bytes = JSON.pretty_generate(root) + "\n"
  File.binwrite(storage.data_path(Q::Drafts::FILE), bytes)
  rejects { drafts.list }
  assert(File.binread(storage.data_path(Q::Drafts::FILE)) == bytes.b,
    'A mismatched draft identity was rewritten instead of rejected')

  partial = Q::Model.new_draft('set')
  partial['items'] << Q::Model.new_question
  legacy = sample.merge('resource_id' => 9, 'resource_name' => 'stored snapshot', 'snapshot' => SecureRandom.uuid)
  root = {'version' => 1, 'accounts' => {'guest' => {'drafts' => {partial['id'] => partial, legacy['id'] => legacy}, 'delivered' => []},
    'other' => {'drafts' => {'broken' => nil}, 'delivered' => []}}}
  File.binwrite(storage.data_path(Q::Drafts::FILE), JSON.generate(root))
  assert(drafts.list == [partial, legacy], 'Validation changed partial/legacy drafts or inspected another account')
  edited = drafts.list
  edited.last['items'][0]['prompt'] = 'Local copy only'
  assert(drafts.list.last['items'][0]['prompt'] == legacy['items'][0]['prompt'], 'Listing exposed mutable recovery storage')
end

puts "PASS question creator nested local recovery: #{@checks} checks"
