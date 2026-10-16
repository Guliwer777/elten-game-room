require 'json'

module ProposalNoticeStorageSupport
  # Mimic the SDK's documented corrupt/missing fallback. The production journal
  # must guard this boundary; this fake does not add that guard for it.
  class Program
    def initialize(directory); @directory=directory; end
    def data_path(name); File.join(@directory,name); end
    def update_json(name,default:)
      path=data_path(name)
      begin
        state=JSON.parse(File.binread(path))
      rescue StandardError
        state=Marshal.load(Marshal.dump(default))
      end
      yield state
      File.binwrite(path,JSON.generate(state))
    end
  end
end
