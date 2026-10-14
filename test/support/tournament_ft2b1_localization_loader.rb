# encoding: UTF-8
require 'json'
require 'digest'

# Binarna granica bez instalatora: wszystkie rekordy pochodzą z jednej mapy
# własnego source. Brak rekordu kończy próbę; nigdy ROOT ani kopia autora J.
module TournamentFT2B1LocalizationLoader
  ROOT = File.expand_path('../..', __dir__)
  @loaded = {}
  class << self
    attr_reader :loaded, :entries
    def prepare
      map = JSON.parse(File.binread(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'source-before.json')))
      @entries = map.select { |p, _| p.end_with?('.rb') && p.start_with?('lib/', 'games/', 'content/') }.to_h do |p, hash|
        raise 'Niebezpieczna ścieżka' if p.split('/').include?('..')
        path = File.join(ROOT, p)
        raise 'Dowiązanie źródła' if File.symlink?(path)
        bytes = File.binread(path)
        raise 'Bajt źródła różny od prepina' unless Digest::SHA256.hexdigest(bytes) == hash
        [path, bytes.freeze]
      end.freeze
      File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'binary-records-before.json'), JSON.pretty_generate(@entries.to_h { |p,b| [p, {sha256: Digest::SHA256.hexdigest(b), encoding: b.encoding.name}] }))
      begin
        @entries.fetch(File.join(ROOT, 'lib/absent-ft2b1-record.rb'))
        raise 'Loader ma fallback'
      rescue KeyError
        # Dodatnia kontrola odmowy nieobecnego rekordu, bez odczytu dysku.
      end
    end
    def production?(path)
      path.start_with?(ROOT + '/lib/', ROOT + '/games/', ROOT + '/content/')
    end
    def load(path)
      return false if @loaded.key?(path)
      bytes = @entries.fetch(path)
      raise 'Źródło nie jest binarne' unless bytes.encoding == Encoding::ASCII_8BIT
      @loaded[path] = {sha256: Digest::SHA256.hexdigest(bytes), encoding: bytes.encoding.name}
      TOPLEVEL_BINDING.eval(bytes, path, 1)
      $LOADED_FEATURES << path unless $LOADED_FEATURES.include?(path)
      true
    end
  end
  module Requires
    def require_relative(name)
      origin = File.expand_path(caller_locations(1, 1).first.path)
      path = File.expand_path(name, File.dirname(origin))
      path += '.rb' unless path.end_with?('.rb')
      if origin.start_with?(TournamentFT2B1LocalizationLoader::ROOT + '/') && TournamentFT2B1LocalizationLoader.production?(path)
        return TournamentFT2B1LocalizationLoader.load(path)
      end
      require File.expand_path(name, File.dirname(origin))
    end
    def require(name)
      path = File.expand_path(name)
      path += '.rb' unless path.end_with?('.rb')
      return TournamentFT2B1LocalizationLoader.load(path) if TournamentFT2B1LocalizationLoader.production?(path)
      super
    end
    private :require_relative, :require
  end
end
