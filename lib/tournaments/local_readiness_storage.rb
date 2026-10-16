# encoding: UTF-8
require_relative 'readiness_contract'
require_relative 'strict_json'
require 'fileutils'
require 'securerandom'
require 'thread'

module GameRoomTournaments
  # Własny magazyn wyłącznie lokalnego K03. Nie otwiera tabel ani sieci.
  class LocalReadinessStorage
    C = ReadinessContract
    MAX_BYTES = 33_554_432
    attr_reader :path

    def initialize(directory:, guard:)
      C.text!(directory)
      value = directory.tr('\\', '/')
      raise C::Invalid, :invalid_directory if value.start_with?('//') || value.match?(/\A[A-Za-z]:(?!\/)/)
      @directory = File.expand_path(value).freeze
      @path = File.join(@directory, 'sandbox-k03.json').freeze
      @guard, @mutex = guard, Mutex.new
      @diagnostics = [].freeze
    end

    def diagnostics
      @diagnostics
    end

    # Walidator należy do backendu. Nawet odczyt sprawdza CAŁY dokument.
    def access(validate:)
      @mutex.synchronize do
        lock = nil
        primary = nil
        begin
          boundary { StrictJson.verify! }
          check_paths(document: false)
          boundary { FileUtils.mkdir_p(@directory, mode: 0o700) }
          check_paths(document: false)
          boundary { lock = File.open(@path + '.lock', File::RDWR | File::CREAT, 0o600) }
          check_open(lock, @path + '.lock')
          raise C::PortUnavailable, 'Nie uzyskano blokady K03' unless boundary { lock.flock(File::LOCK_EX) }
          check_paths
          document = read
          validate.call(document) if document
          yield document
        rescue Exception => error
          primary = error
          raise error, cause: error.cause
        ensure
          begin
            cleanup(primary) { lock.close } if lock && !lock.closed?
          ensure
            raise primary, cause: primary.cause if primary
          end
        end
      end
    end

    def write(document)
      bytes = JSON.generate(document)
      raise C::Blocked, :sandbox_limit if bytes.bytesize > MAX_BYTES
      temporary = @path + '.tmp-' + SecureRandom.hex(12)
      file = nil
      created = false
      primary = nil
      begin
        boundary { file = File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600); created = true }
        check_open(file, temporary)
        boundary { file.binmode }
        raise C::PortUnavailable, 'Niepełny zapis K03' unless boundary { file.write(bytes) } == bytes.bytesize
        boundary { file.flush }
        boundary { file.fsync }
        boundary { file.close }
        check_paths
        boundary { File.rename(temporary, @path) }
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          cleanup(primary) { file.close } if file && !file.closed?
        ensure
          begin
            cleanup(primary) { File.delete(temporary) if File.exist?(temporary) } if created
          ensure
            raise primary, cause: primary.cause if primary
          end
        end
      end
      nil
    end

    private

    def boundary
      @guard.call
      primary = nil
      begin
        yield
      rescue IOError, SystemCallError => error
        primary = C::PortUnavailable.new('Niepewne I/O lokalnego K03')
        raise primary, cause: error
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          @guard.call
        ensure
          raise primary, cause: primary.cause if primary
        end
      end
    end

    def cleanup(primary)
      yield
    rescue Exception => error
      @diagnostics = (@diagnostics.last(3) + [{
        'attempt_id' => SecureRandom.uuid, 'class' => error.class.name.to_s.byteslice(0,128).scrub,
        'message' => error.message.to_s.encode('UTF-8', invalid: :replace, undef: :replace).byteslice(0,512).scrub
      }.freeze]).freeze
      raise error, cause: error.cause unless primary
    ensure
      raise primary, cause: primary.cause if primary
    end

    def stat(path)
      boundary { File.lstat(path) }
    rescue C::PortUnavailable => error
      return nil if error.cause.is_a?(Errno::ENOENT)
      raise
    end

    def check_paths(document: true)
      path = @directory
      loop do
        value = stat(path)
        raise C::Blocked, :unsafe_sandbox if value && (value.symlink? || !value.directory?)
        parent = File.dirname(path)
        break if parent == path
        path = parent
      end
      # Inspect the replaceable document only under its process lock. Even a
      # metadata read can briefly prevent another process's rename on Windows.
      # The directory and stable lock file must still be checked before opening.
      files = document ? [@path, @path + '.lock'] : [@path + '.lock']
      files.each do |file|
        value = stat(file)
        raise C::Blocked, :unsafe_sandbox if value && (value.symlink? || !value.file? || value.nlink != 1)
      end
    end

    def check_open(file, path)
      value = boundary { file.stat }
      unless value.file? && value.nlink == 1 && boundary { File.identical?(file, path) }
        raise C::Blocked, :unsafe_sandbox
      end
    end

    def read
      return nil unless stat(@path)
      bytes = boundary { File.binread(@path, MAX_BYTES + 1) }
      raise C::Blocked, :sandbox_limit if bytes.bytesize > MAX_BYTES
      document = StrictJson.parse(bytes, max_nesting: 24)
      raise C::Blocked, :sandbox_corrupt unless document.is_a?(Hash)
      document
    rescue JSON::ParserError, EncodingError
      raise C::Blocked, :sandbox_corrupt
    end
  end
end
