# encoding: UTF-8
require_relative 'tournament_readiness_fixture'
module TournamentReadinessFixture
  # Plikowa symulacja wyłącznie testów procesowych; nie provider aplikacji.
  class FilePort < Port
    def initialize(directory)
      super()
      @remote=File.join(directory,'test-server.json')
    end
    def transaction
      File.open(@remote+'.lock',File::RDWR|File::CREAT,0o600) do |lock|
        lock.flock(File::LOCK_EX)
        if File.file?(@remote)
          data=JSON.parse(File.read(@remote))
          @view=data['view']; @operations=data['operations']; @calls=data['calls'].map(&:to_sym)
        end
        begin
          yield
        ensure
          persist
        end
      end
    end
    def persist
      File.open(@remote+'.tmp','wb') do |file|
        file.write(JSON.generate({'view'=>@view,'operations'=>@operations,'calls'=>@calls}))
        file.flush; file.fsync
      end
      File.rename(@remote+'.tmp',@remote)
    end
    def event(name,value)
      persist if name==:store_after
      super
    end
    def snapshot(scope:,match_ref:)
      transaction { super }
    end
    def store(operation:)
      transaction { super }
    end
    def lookup(operation:)
      transaction { super }
    end
  end
end
