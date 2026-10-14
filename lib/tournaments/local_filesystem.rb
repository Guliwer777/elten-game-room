module GameRoomTournaments
  # Preserve logical paths and identity; only native I/O needs the Windows prefix.
  module LocalFilesystem
    def self.native(path)
      return path unless File::ALT_SEPARATOR == '\\' && path.is_a?(String) && path.bytesize >= 248
      normalized = path.tr('\\', '/')
      return path unless normalized.match?(/\A[A-Za-z]:\//)
      '\\\\?\\' + normalized.tr('/', '\\')
    end
  end
end
