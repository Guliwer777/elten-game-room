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

Dir.mktmpdir('quiz-null-storage-') do |directory|
  runtime = Programs::Runtime.allocate
  runtime.instance_variable_set(:@json_file_monitors, {})
  runtime.instance_variable_set(:@json_file_monitors_guard, Monitor.new)
  runtime.define_singleton_method(:data_dir) { directory }
  drafts = Q::Drafts.new(runtime, user: 'guest', current_user: -> { 'guest' })
  path = runtime.data_path(Q::Drafts::FILE)
  value = Q::Model.new_draft('set').merge('title' => nil, 'language' => nil, 'description' => nil,
    'snapshot' => SecureRandom.uuid, 'resource_id' => 9, 'resource_name' => 'saved-name', 'opaque' => {'a' => nil})
  value['items'] << Q::Model.new_question.merge('prompt' => nil, 'category' => nil, 'source' => nil,
    'note' => nil, 'choices' => [nil, '  untrimmed  ', nil, ''], 'correct_index' => 3)
  root = {'version' => 1, 'accounts' => {'guest' => {'drafts' => {value['id'] => value}, 'delivered' => []}}}
  bytes = JSON.generate(root)
  File.binwrite(path, bytes)
  listed = drafts.list.fetch(0)
  assert(File.binread(path) == bytes.b, 'Native read rewrote nullable recovery bytes')
  assert(Q::Model.draft(listed) == Q::Model.draft(value), 'Recovery changed canonical content')
  assert(%w[title language description].all? { |key| listed[key] == '' }, 'Draft nulls are not empty UI text')
  assert(%w[prompt category source note].all? { |key| listed['items'][0][key] == '' }, 'Question nulls are not empty UI text')
  assert(listed['items'][0]['choices'] == ['', '  untrimmed  ', '', ''], 'Choice projection changed typed content')
  assert(listed['items'][0]['correct_index'] == 3, 'Read-only recovery moved the correct answer')
  assert(listed.values_at('snapshot', 'resource_id', 'resource_name', 'opaque') ==
    value.values_at('snapshot', 'resource_id', 'resource_name', 'opaque'), 'Recovery metadata was normalized')
  listed['opaque']['a'] = 'only working copy'
  assert(drafts.list.first['opaque']['a'].nil?, 'Working copy reached persistent recovery')
  saved = drafts.save(drafts.list.first)
  assert(saved['snapshot'] == value['snapshot'], 'Saving equivalent nullable content changed an uncertain operation identity')
  assert(Q::Model.draft(saved) == Q::Model.draft(value), 'Explicit save changed canonical questions')
  assert(Dir.glob(path + '.tmp-*').empty?, 'Native read/save left temporary files')
end
puts "PASS nullable native recovery storage: #{@checks} checks"
