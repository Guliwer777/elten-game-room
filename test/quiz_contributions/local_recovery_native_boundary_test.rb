require_relative '../support/host_source'
require EltenTestHost.file('src/bootstrap.rb')
require EltenTestHost.file('src/eapi/resources.rb')
require EltenTestHost.file('src/eapi/program.rb')
require_relative '../support/quiz_contributions'
include QuestionContributionTest
Q = GameRoomQuizContributions

module Log
  def self.debug(_message); end
end

Dir.mktmpdir('quiz-recovery-native-') do |directory|
  runtime = Programs::Runtime.allocate
  runtime.instance_variable_set(:@json_file_monitors, {})
  runtime.instance_variable_set(:@json_file_monitors_guard, Monitor.new)
  runtime.define_singleton_method(:data_dir) { directory }
  account = 'guest'
  drafts = Q::Drafts.new(runtime, user: account, current_user: -> { account })
  path = runtime.data_path(Q::Drafts::FILE)
  ordinary = sample
  ordinary['items'][0]['correct_index'] = 3
  ordinary['snapshot'] = SecureRandom.uuid
  ordinary['resource_id'] = 37
  ordinary['resource_name'] = 'previous-private-snapshot'
  ordinary['local_extension'] = {'retain' => ['opaque']}
  partial = Q::Model.new_draft('set')
  partial['items'] << Q::Model.new_question
  valid_root = {'version' => 1, 'accounts' => {
    'guest' => {'drafts' => {ordinary['id'] => ordinary, partial['id'] => partial}, 'delivered' => ['receipt']},
    'another' => {'drafts' => {'damaged-but-not-this-account' => nil}, 'delivered' => []}}}

  # A shallow-valid row with a malformed nested choice must fail before the
  # native update_json writer commits, even if earlier rows are valid.
  invalid = Q::Model.copy(ordinary)
  invalid['id'] = SecureRandom.uuid
  invalid['items'][0]['choices'][2] = {'wrong' => 'shape'}
  broken = Q::Model.copy(valid_root)
  broken['accounts']['guest']['drafts'][invalid['id']] = invalid
  bytes = JSON.pretty_generate(broken) + "\n"
  File.binwrite(path, bytes)
  rejects { drafts.list }
  assert(File.binread(path) == bytes.b, 'Native recovery validation rewrote the rejected source')

  File.binwrite(path, JSON.generate(valid_root))
  values = drafts.list
  assert(values == [ordinary, partial], 'Native listing changed legacy/partial content or opaque recovery fields')
  assert(Q::Model.packet(values.first, author: 'guest') == Q::Model.packet(ordinary, author: 'guest'),
    'Read-only listing changed the previously submitted packet identity')
  values.first['items'][0]['choices'][3] = 'Only a detached working copy'
  values.first['local_extension']['retain'] << 'Not in storage'
  assert(drafts.list == [ordinary, partial], 'Nested listed values were not detached from recovery')
  assert(JSON.parse(File.binread(path)) == valid_root, 'Native successful list changed stored content')

  # Legacy partial drafts may omit text keys entirely, not only contain null.
  # Keep their bytes/opaque fields while making the detached UI copy usable.
  sparse = Q::Model.copy(partial)
  %w[title language description].each { |key| sparse.delete(key) }
  %w[prompt category source note].each { |key| sparse['items'][0].delete(key) }
  sparse['items'][0]['choices'] = [nil, '  preserved  ', '', nil]
  sparse['items'][0]['correct_index'] = 3
  sparse['extension'] = {'missing' => nil, 'empty' => ''}
  sparse_root = Q::Model.copy(valid_root)
  sparse_root['accounts']['guest']['drafts'][partial['id']] = sparse
  sparse_bytes = JSON.generate(sparse_root)
  File.binwrite(path, sparse_bytes)
  recovered = drafts.list.last
  assert(%w[title language description].all? { |key| recovered[key] == '' } &&
    %w[prompt category source note].all? { |key| recovered['items'][0][key] == '' },
    'Missing valid text keys were not safe for native list/edit consumers')
  assert(Q::Model.categories(recovered).empty? && recovered['items'][0]['choices'] == ['', '  preserved  ', '', ''],
    'Sparse recovery invented a category or normalized typed answers')
  assert(Q::Model.draft(recovered) == Q::Model.draft(sparse) && recovered['items'][0]['correct_index'] == 3 &&
    recovered['extension'] == sparse['extension'], 'Sparse editor projection changed canonical content or opaque fields')
  assert(File.binread(path) == sparse_bytes.b, 'Reading sparse native recovery rewrote the original bytes')
  File.binwrite(path, JSON.generate(valid_root))

  # Switching accounts while the native reader is finishing must abort before
  # returning private drafts or committing even an otherwise valid JSON file.
  native_reader = runtime.method(:read_json_file)
  runtime.define_singleton_method(:read_json_file) do |*arguments, &fallback|
    result = native_reader.call(*arguments, &fallback)
    account = 'another'
    result
  end
  before = File.binread(path)
  rejects(Q::Unavailable) { drafts.list }
  assert(File.binread(path) == before, 'Account change committed the wrong account recovery')
  runtime.singleton_class.remove_method(:read_json_file)
  account = 'guest'
  assert(drafts.list == [ordinary, partial], 'An interrupted account read destroyed the original drafts')
  assert(Dir.glob(path + '.tmp-*').empty?, 'Native recovery validation left temporary files')
end
puts "PASS native local recovery transaction boundaries: #{@checks} checks"
