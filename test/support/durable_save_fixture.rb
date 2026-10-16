# encoding: UTF-8
require 'json'
require 'base64'
require 'tmpdir'
require 'socket'
require 'net/http'
require_relative 'native_room_harness'
require_relative '../../games/four_in_a_row'
require_relative '../../lib/account_saved_games'
require_relative '../../lib/use_cases/save_game'

module DurableSaveFixture
  module NoNetwork
    def connect(*); raise 'Sieć zabroniona w próbie'; end
    def connect_nonblock(*); raise 'Sieć zabroniona w próbie'; end
  end
  Socket.prepend(NoNetwork)
  TCPSocket.singleton_class.prepend(Module.new do
    def new(*); raise 'Sieć zabroniona w próbie'; end
    def open(*); raise 'Sieć zabroniona w próbie'; end
  end)
  Net::HTTP.prepend(Module.new do
    def request(*); raise 'HTTP zabronione w próbie'; end
  end)
  module_function
  def program
    Object.new.tap do |object|
      %i[data_path read_json write_json update_json].each do |name|
        object.define_singleton_method(name) { |*| raise 'Żywy profil zabroniony' }
      end
    end
  end
  def root!(root)
    expected = File.expand_path(ENV.fetch('TMPDIR'))
    raise 'Brak izolacji próby' unless File.expand_path(root).start_with?(expected + '/')
  end
  def dump(path, value)
    root!(path)
    File.binwrite(path, JSON.generate(value).encode('UTF-8'))
  end
  def read(path); JSON.parse(File.binread(path)); end
  def intent(root, owner: 'Alice', backend: 'test-private-resources:v1', account: -> { Session.name })
    GameRoomSavedGameSaveIntent.new(directory: File.join(root, 'intents'), owner: owner,
      backend_identity: backend, account: account)
  end
  def room
    h = NativeRoomHarness.new(game: GameRoomGames::FourInARow.new, users: %w[Alice Bob])
    h.start
    h.write('Alice', [GameRoomGames::EventCommand.new(action: 'drop', value: '3')])
    h.write('Bob', [GameRoomGames::EventCommand.new(action: 'drop', value: '4')])
    h
  end
  def save_room(root, h)
    core = h.core
    fields = core.to_h.reject { |key, _| %i[views mutex participants dedup].include?(key) }
    fields[:participants] = core.participants.transform_values(&:to_h)
    dump(File.join(root, 'test-service-stack.json'), {'core'=>fields, 'table'=>h.table})
  end
  def load_room(root)
    data = read(File.join(root, 'test-service-stack.json'))
    values = data.fetch('core').transform_keys(&:to_sym)
    values[:visibility] = values[:visibility].to_sym
    values[:participants] = values[:participants].transform_values { |p| NativeLiveSessionsBroker::Participant.new(**p.transform_keys(&:to_sym)) }
    values[:views], values[:mutex] = [], Mutex.new
    values[:dedup] = values[:entries].to_h { |e| [[e.dig('sender','user'),e['message_id']],e['seq']] }
    broker = NativeLiveSessionsBroker.new
    core = NativeLiveSessionsBroker::Core.new(**values)
    broker.cores[core.id] = core
    h = NativeRoomHarness.allocate
    {broker: broker, users: %w[Alice Bob], game: GameRoomGames::FourInARow.new,
      transports: {}, repositories: {}, table: data.fetch('table')}.each { |k,v| h.instance_variable_set("@#{k}",v) }
    h.users.each { |u| h.add_client(u); assert(h.join(u), 'Nie odtworzono testowego połączenia') }
    session = h.as('Alice') { h.repositories['Alice'].session_for_table(h.table, force: true) }
    h.instance_variable_set(:@session, session)
    h
  end
  def use_case(h, archive)
    GameRoomUseCases::SaveGame.new(repository: h.repositories['Alice'], transport: h.transports['Alice'], archives: -> { archive })
  end
  def arguments(h)
    {table: h.table, table_id: h.table['__id'], session: h.session, game: h.game}
  end

  class Resources
    Resource = Struct.new(:id, :resource, :uploader, :filesize, :meta, keyword_init: true)
    attr_accessor :lost_reply, :read_failure, :intent, :before_upload, :quota, :failure
    attr_reader :used_size
    def initialize(root)
      DurableSaveFixture.root!(root)
      @path = File.join(root,'test-service-private-resources.json')
      @quota = 16 * 1024 * 1024
    end
    def state
      File.exist?(@path) ? DurableSaveFixture.read(@path) : {'uploads'=>0,'resources'=>[]}
    end
    def list(timeout:)
      raise IOError, 'Odczyt po wysyłce niedostępny' if read_failure && state['uploads'] > 0
      data = state
      @used_size = data['resources'].sum { |r| r['filesize'] }
      data['resources'].map { |r| Resource.new(**r.reject { |k,_| k == 'data' }.transform_keys(&:to_sym)) }
    end
    def max_private_resources_bytes_per_user; @quota; end
    def upload(name, data, meta:, timeout:)
      before_upload&.call
      if intent
        operation = intent.list.fetch(0)
        assert(operation['status'] == 'attempted', 'Wysyłka bez trwałego attempted')
        assert(operation.dig('values','manifest') == meta, 'Inny manifest przed I/O')
        assert(operation.dig('values','sha256') == Digest::SHA256.hexdigest(Zlib::Inflate.inflate(data)), 'Inne bajty przed I/O')
        DurableSaveFixture.dump(@path + '.intent-before-upload.json', operation)
      end
      document = state
      id = document['uploads'] + 1
      row = {'id'=>id,'resource'=>name,'uploader'=>'Alice','filesize'=>data.bytesize,'meta'=>meta,'data'=>Base64.strict_encode64(data)}
      document['uploads'] = id
      document['resources'] << row
      DurableSaveFixture.dump(@path, document)
      raise failure if failure
      raise IOError, 'Odpowiedź upload utracona' if lost_reply
      Resource.new(**row.reject { |k,_| k == 'data' }.transform_keys(&:to_sym))
    end
    def download(id, timeout:)
      row = state['resources'].find { |r| r['id'] == id }
      raise IOError, 'Brak zasobu' unless row
      Base64.strict_decode64(row.fetch('data'))
    end
  end
end
