# encoding: UTF-8
# Jawne zasoby testowe; nie wczytują scenariuszy ani żywego programu.
require_relative 'native_tasks'
module TournamentEntryContextTest
  # Zdarzenia są bodźcem prób ABA, a nie ręczną edycją Hasha kontekstu.
  class Events
    Subscription = Struct.new(:dispose) do
      def close
        callback, self.dispose = dispose, nil
        callback&.call
      end
    end
    attr_reader :listeners
    def initialize(value)
      @value, @epoch, @listeners = value, 1, []
    end
    def snapshot
      {value: @value, epoch: @epoch}.freeze
    end
    def subscribe(&block)
      @listeners << block
      Subscription.new(-> { @listeners.delete(block) })
    end
    def emit(value)
      @value = value
      @epoch += 1
      @listeners.dup.each { |listener| listener.call(snapshot) }
    end
  end

  class Program
    attr_reader :managed_resources, :path_calls
    class << self
      attr_accessor :app_runtime
    end
    def initialize(path = nil)
      @path, @path_calls = path, []
      @managed_resources = EltenAPI::Resources::Registry.new
      self.class.app_runtime = TestTaskRuntime.new('entry-test')
    end
    def manage(resource); @managed_resources.manage(resource); end
    def release(resource); @managed_resources.release(resource); end
    def data_path
      @path_calls << Thread.current
      raise 'Nieoczekiwany dostęp do katalogu' unless @path
      @path
    end
    def finalize; @managed_resources.close; end
  end
end
