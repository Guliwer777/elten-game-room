require_relative '../support/quiz_creator_native'
require_relative '../support/quiz_contributions'
%w[client apps attachments messages].each { |name| require EltenTestHost.file("src/eltenlink/#{name}.rb") }
require EltenTestHost.file('src/eapi/tasks.rb')

NativeOptionTest.language = 'en'
module Session
  class << self
    attr_accessor :name
  end
end
Session.name = 'guest'
Q = GameRoomQuizContributions

# Exercise the host's actual resource, message and attachment SDK. Only HTTP
# is replaced; the production RequestClient must carry its account/token and
# finite request timeout through every SDK stage.
class CreatorHttpBoundary
  attr_reader :calls, :resources, :messages, :deleted, :attachments
  attr_accessor :lose_message_ack, :after_attachment

  def initialize(user, token:)
    @user, @token, @calls, @resources, @messages, @deleted, @attachments = user, token, [], [], [], [], {}
    @next_id = 1
  end

  def api_data(method, path, params = nil, **options)
    record(method, path, options)
    if path == '/api/v1/apps/audit-creator/private-resources'
      return {'resources' => @resources.map { |row| row.reject { |key, _| key == 'data' } },
        'max_private_resources_bytes_per_user' => 16 * 1024 * 1024} if method == 'GET'
    elsif path =~ %r{\A/api/v1/apps/audit-creator/private-resources/(\d+)\z} && method == 'DELETE'
      @resources.reject! { |row| row['id'] == Regexp.last_match(1).to_i }
      return {}
    elsif path == '/api/v1/messages'
      if method == 'GET'
        rows = @messages.select { |row| row['subject'] == params['subject'] && !@deleted.include?(row['id']) }
        return {'messages' => rows, 'more' => false, 'can_reply' => true, 'name' => 'papierek'}
      elsif method == 'POST'
        @messages << {'id' => @messages.size + 1, 'sender' => @user, 'subject' => params['subject'],
          'message' => params['text'], 'attachments' => params['attachments'].to_s.split(','),
          'date' => 123, 'polls' => []}
        if @lose_message_ack
          @lose_message_ack = false
          raise IOError, 'Accepted message response lost'
        end
        return {}
      end
    elsif path =~ %r{\A/api/v1/messages/(\d+)\z} && method == 'DELETE'
      @deleted << Regexp.last_match(1).to_i
      return {}
    end
    raise "Unexpected SDK request #{method} #{path} #{params.inspect}"
  end

  def api_payload(method, path, params = nil, **options)
    record(method, path, options)
    if method == 'GET' && path =~ %r{\A/api/v1/attachments/(.+)\z}
      attachment = @attachments.fetch(Regexp.last_match(1))
      return {'success' => true, 'data' => {'name' => attachment[:name], 'size' => attachment[:bytes].bytesize,
        'uploader' => @user, 'url' => 'https://invalid.example/local-only'}}
    end
    raise "Unexpected SDK payload #{method} #{path} #{params.inspect}"
  end

  def api_binary_data(method, path, data, headers = {}, params = nil, **options)
    record(method, path, options)
    if method == 'POST' && path == '/api/v1/apps/audit-creator/private-resources'
      row = {'id' => @next_id, 'appid' => 'audit-creator', 'uploader' => @user,
        'resource' => params.fetch('resource'), 'meta' => params.fetch('meta', ''), 'filesize' => data.bytesize,
        'url' => 'https://invalid.example/local-only', 'data' => data.dup}
      @next_id += 1
      @resources << row
      return row.reject { |key, _| key == 'data' }
    elsif method == 'POST' && path == '/api/v1/attachments'
      id = SecureRandom.hex(8)
      @attachments[id] = {name: headers.fetch('X-Elten-Filename'), bytes: data.dup}
      @after_attachment&.call
      return {'id' => id}
    end
    raise "Unexpected SDK binary #{method} #{path}"
  end

  def api_download(path, **options)
    record('GET', path, options)
    id = path.match(%r{\A/api/v1/apps/audit-creator/private-resources/(\d+)/download\z})&.captures&.first
    raise "Unexpected download #{path}" unless id
    @resources.find { |row| row['id'] == id.to_i }.fetch('data').dup
  end

  private

  def record(method, path, options)
    assert([15, 30].include?(options[:timeout]), 'Native request has no bounded timeout')
    assert(options[:cancellation_token].equal?(@token), 'Native request dropped or changed the cancellation token')
    options[:cancellation_token]&.raise_if_cancelled!
    @calls << [method, path, options.dup]
  end
end

token = EltenAPI::Tasks::CancellationToken.new
client = CreatorHttpBoundary.new('guest', token: token)
repo = Q::Repository.new(app_uuid: 'audit-creator', user: 'guest', current_user: -> { Session.name }, client: client)
delivery = Q::Delivery.new(repo)
Dir.mktmpdir('creator-native-delivery-') do |directory|
  drafts = Q::Drafts.new(QuestionContributionTest::Storage.new(directory), user: 'guest', current_user: -> { Session.name })
  value = drafts.save(QuestionContributionTest.sample)
  saved = repo.save(value, token: token)
  assert(repo.read(repo.list(token: token).first, token: token)['items'] == value['items'], 'Native resource SDK changed the question payload')
  packet = Q::Model.packet(saved, author: 'guest')
  client.lose_message_ack = true
  begin
    delivery.send(packet, token: token)
    raise 'Lost acknowledgement was not injected'
  rescue IOError => error
    assert(error.message == 'Accepted message response lost', 'Unexpected native delivery failure')
  end
  assert(client.messages.size == 1 && client.attachments.size == 1, 'Initial send did not use one native attachment/message')
  assert(delivery.send(packet, token: token) && client.messages.size == 1 && client.attachments.size == 1,
    'Retry of an accepted message uploaded or sent a second copy')
  assert(repo.record_delivery(packet['submission_id'], token: token), 'Native receipt was not verified')
  delivery.remove_sender_copy(packet, token: token)
  assert(client.deleted == [1] && repo.delivered?(packet['submission_id'], token: token), 'Cleanup lost account-wide delivery evidence')
  repo.delete(saved, token: token)
  assert(repo.list(token: token).empty? && client.resources.size == 1, 'Draft cleanup removed the receipt or left a draft')

  # Authentication changes between attachment upload and message POST must
  # stop before sending; there is no fallback to another account's mailbox.
  second = Q::Model.packet(value.merge('description' => 'Another proposal'), author: 'guest')
  client.after_attachment = -> { Session.name = 'another' }
  begin
    delivery.send(second, token: token)
    raise 'Account switch was accepted'
  rescue Q::Unavailable
    assert(client.messages.size == 1 && client.deleted == [1], 'Account switch sent or removed a message')
  ensure
    client.after_attachment = nil
    Session.name = 'guest'
  end

  # Reports use the same RequestClient and native Messages API, without an attachment.
  reports = GameRoomQuizReports::Delivery.new(repo)
  question = {'id' => 'q1', 'prompt' => 'Which tree?', 'answers' => %w[Oak Pine Beech Maple],
    'correct' => 'Pine', 'category' => 'Nature', 'language' => 'en', 'set' => 'general'}
  report = reports.packet(question, 'Please check this wording.')
  assert(reports.send_and_clean(report, token: token), 'Native report delivery failed')
  assert(client.messages.size == 2 && client.deleted == [1, 2] && client.messages.last['attachments'].empty?,
    'Report created an attachment or left the sender copy')
  assert(reports.send_and_clean(report, token: token) && client.messages.size == 2, 'Report cleanup retry duplicated the message')
  count = client.calls.size
  token.cancel
  begin
    repo.list(token: token)
    raise 'Cancelled resource read was allowed'
  rescue EltenAPI::Tasks::Cancelled
    assert(client.calls.size == count, 'Cancellation reached HTTP instead of stopping at the boundary')
  end
end

puts "PASS native creator/report SDK boundaries: #{$assertions} checks"
