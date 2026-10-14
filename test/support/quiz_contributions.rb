require 'tmpdir'
require 'fileutils'
require_relative '../../lib/quiz_contributions/model'
require_relative '../../lib/quiz_contributions/drafts'
require_relative '../../lib/quiz_contributions/repository'
require_relative '../../lib/quiz_contributions/delivery'

module QuestionContributionTest
  extend self
  attr_reader :checks
  def assert(value, message)
    @checks = @checks.to_i + 1
    raise message unless value
  end
  def rejects(type = GameRoomQuizContributions::Invalid)
    begin
      yield
    rescue type
      assert(true, 'rejected')
      return
    end
    raise 'Expected rejection'
  end

  def sample
    value = GameRoomQuizContributions::Model.new_draft('set')
    value.merge!('title' => 'Próba żółwia', 'language' => 'pl')
    value['items'][0] = {'prompt' => 'Które z tych drzew ma igły?', 'choices' => %w[Dąb Buk Sosna Klon],
      'correct_index' => 2, 'category' => 'Przyroda', 'source' => '', 'note' => ''}
    value
  end

  class Storage
    attr_accessor :fail
    def initialize(path); @path = path; @lock = Mutex.new; end
    def data_path(file); File.join(@path, file); end
    def update_json(file, default:)
      @lock.synchronize do
        raise IOError, 'disk unavailable' if @fail
        value = begin JSON.parse(File.read(data_path(file))); rescue IOError, SystemCallError, JSON::ParserError; Marshal.load(Marshal.dump(default)); end
        yield value
        File.write(data_path(file), JSON.generate(value))
        value
      end
    end
  end

  Resource = Struct.new(:id, :resource, :meta, :uploader, :filesize, :data, keyword_init: true)
  class Files
    attr_accessor :user, :fail, :after_call
    attr_reader :rows, :calls
    def initialize
      @user, @rows, @calls, @next_id = 'guest', [], [], 1
    end
    def private_resources(_client, _uuid); self; end
    def check(operation, token, after: false)
      token&.raise_if_cancelled!
      @calls << operation unless after
      if @fail == [operation, after]
        @fail = nil
        raise IOError, 'network interrupted'
      end
      @after_call&.call(operation) if after
    end
    def list(timeout:, cancellation_token:)
      check(:list, cancellation_token)
      result = @rows.select { |r| r.uploader == @user }.map(&:dup)
      check(:list, cancellation_token, after: true)
      result
    end
    def upload(name, bytes, meta:, timeout:, cancellation_token:)
      check(:upload, cancellation_token)
      row = Resource.new(id: @next_id, resource: name, meta: meta, uploader: @user, filesize: bytes.bytesize, data: bytes)
      @next_id += 1
      @rows << row
      check(:upload, cancellation_token, after: true)
      row.dup
    end
    def download(ref, timeout:, cancellation_token:)
      check(:download, cancellation_token)
      row = @rows.find { |r| r.id == ref.id && r.uploader == @user } or raise IOError, 'not found'
      check(:download, cancellation_token, after: true)
      row.data.dup
    end
    def delete(ref, timeout:, cancellation_token:)
      check(:delete, cancellation_token)
      @rows.delete_if { |r| r.id == ref.id && r.uploader == @user }
      check(:delete, cancellation_token, after: true)
      true
    end
  end

  Message = Struct.new(:id, :sender, :receiver, :subject, :text, :attachments, :attachments_names, :payload, keyword_init: true)
  Response = Struct.new(:messages, :more, keyword_init: true)
  class Mailbox
    attr_accessor :fail, :more, :user
    attr_reader :rows, :paths, :deleted
    def initialize
      @rows, @paths, @user, @more, @deleted = [], [], 'guest', false, []
    end
    def messages(_client, user:, subject:, limit:)
      raise IOError, 'cannot check inbox' if @fail == :read
      Response.new(messages: @rows.select { |m| m.receiver == user && m.subject == subject && !@deleted.include?(m.id) }.first(limit), more: @more)
    end
    def send_text(_client, to:, subject:, text:, attachments:)
      raise IOError, 'before send' if @fail == :before
      @paths += attachments
      payload = Zip::File.open(attachments.first) { |zip| zip.entries.to_h { |e| [e.name, zip.read(e.name)] } }
      @rows << Message.new(id: @rows.size + 1, sender: @user, receiver: to, subject: subject, text: text,
        attachments: ['server-attachment'], attachments_names: attachments.map { |p| File.basename(p) }, payload: payload)
      if @fail == :after
        @fail = nil
        raise IOError, 'acknowledgement lost'
      end
      true
    end
    def delete_message(_client, id)
      raise IOError, 'cannot remove message' if @fail == :delete
      @deleted << id
      true
    end
  end
end
