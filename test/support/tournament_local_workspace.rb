# encoding: UTF-8
require_relative 'temporary_directory'
require_relative 'tournament_public_service'
require_relative 'native_tasks'
require_relative '../../lib/game_room_localization'
require_relative '../../lib/game_content'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})

# Tylko izolowany proces: zachowujemy prawdziwy Tasks.run i jego worker.
module EltenAPI
  def loop_update
    Thread.pass
  end
end

module TournamentLocalWorkspaceSupport
  include TournamentPublicServiceSupport

  class Context
    attr_accessor :user, :now, :path, :on_path
    attr_reader :directory, :program, :alerts, :path_threads, :ui_thread

    def initialize(directory)
      @directory = File.expand_path(directory)
      @path = @directory
      @user, @now = 'RealOwner', 150
      @alerts, @path_threads = [], []
      @ui_thread = Thread.current
      owner = self
      @program = Object.new
      @program.define_singleton_method(:data_path) do
        owner.path_threads << Thread.current
        owner.on_path&.call
        owner.path
      end
    end

    def workspace(actor = 'Testowa Alicja', **options)
      GameRoomTournaments::LocalWorkspace.new(program: @program, registry: GameRoomGames::CATALOG,
        user: -> { @user }, actor: actor, clock: -> { @now },
        alert: ->(message) { raise 'Alert poza UI' unless Thread.current == @ui_thread; @alerts << message }, **options)
    end

    def provider_path
      File.join(@directory, 'tournament-local-test-' + Digest::SHA256.hexdigest(@user.downcase),
        'tables', GameRoomTournaments::LocalTestTables::FILE_NAME)
    end
  end

  def sandbox
    GameRoomTest::TemporaryDirectory.create('tournament-local-workspace-') { |directory| yield Context.new(directory) }
  end

  def local_params(**changes)
    params(timezone: 'local_test:system', **changes)
  end

  def instrument(object, method, &hook)
    original = object.method(method)
    object.define_singleton_method(method) { |*args, **kwargs, &block| hook.call(original, *args, **kwargs, &block) }
    original
  end

  def task_hooks(before: nil, after: nil)
    original = EltenAPI::Tasks.method(:run)
    EltenAPI::Tasks.define_singleton_method(:run) do |**options, &block|
      raise 'Niepoprawne opcje taska' unless options[:ui] == :none && options[:cancellable] == false
      before&.call
      result = original.call(**options, &block)
      after&.call
      result
    end
    yield
  ensure
    EltenAPI::Tasks.define_singleton_method(:run, original)
  end
end
