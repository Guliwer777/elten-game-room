# encoding: UTF-8
require 'fileutils'
require 'securerandom'
require_relative 'publication'
require_relative 'strict_json'

module GameRoomTournaments
  # Osobny lokalny K02. Nigdy nie otwiera magazynu K03 ani tabel serwera.
  class LocalExecutionPlanStorage
    Data = Publication::Data
    Invalid = Publication::Invalid
    MAX_BYTES = 8_388_608
    MAX_RECORDS = 32
    attr_reader :path, :last_write_state, :diagnostics

    def initialize(directory:, guard:)
      unless Data.text?(directory) && directory.bytesize.between?(1, 4096) &&
          directory.match?(/[^[:space:]]/) && !directory.match?(/[[:cntrl:]]/)
        raise Invalid, :invalid_directory
      end
      value = directory.tr('\\', '/')
      raise Invalid, :invalid_directory if value.start_with?('//') || value.match?(/\A[A-Za-z]:(?!\/)/)
      @directory = File.expand_path(value).freeze
      @path = File.join(@directory, 'sandbox-k02.json').freeze
      @guard, @mutex = guard, Mutex.new
      @diagnostics = [].freeze
      @last_write_state = :not_started
    end

    def access(validate:, read_failure: nil)
      @mutex.synchronize do
        @read_provenance = {} if read_failure
        begin
          @attempt_id = SecureRandom.uuid.freeze
          boundary { StrictJson.verify! }
          check_paths
          boundary { FileUtils.mkdir_p(@directory, mode: 0o700) }
          check_paths
          resource(@path + '.lock', File::RDWR | File::CREAT) do |lock|
            raise IOError, 'Brak blokady K02' unless boundary { lock.flock(File::LOCK_EX) }
            check_paths
            document = read_document
            boundary { validate.call(document) } if document
            @inside, @validator = Thread.current, validate
            begin
              boundary { yield document }
            ensure
              @inside = @validator = nil
            end
          end
        rescue Invalid, IOError, SystemCallError => error
          raise unless read_failure && !error.equal?(@read_provenance[:guard_error])
          raise read_failure, cause: error
        ensure
          @read_provenance = nil
        end
      end
    end

    def write(document)
      raise Invalid, :outside_access unless @inside.equal?(Thread.current)
      @last_write_state = :not_started
      copy = bounded(document)
      boundary { @validator.call(copy) }
      bytes = JSON.generate(copy)
      temporary = @path + '.tmp-' + SecureRandom.hex(12)
      created = false
      primary = nil
      @last_write_state = :before_replace
      begin
        resource(temporary, File::WRONLY | File::CREAT | File::EXCL, on_open: -> { created = true }) do |file|
          boundary { file.binmode }
          raise IOError, 'Niepełny zapis K02' unless boundary { file.write(bytes) } == bytes.bytesize
          boundary { file.flush }
          boundary { file.fsync }
        end
        check_paths
        boundary do
          @last_write_state = :replace_attempted
          File.rename(temporary, @path)
          @last_write_state = :replaced
        end
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        cleanup(primary, 'temporary') { File.delete(temporary) if created && File.exist?(temporary) }
      end
      nil
    end

    private

    def resource(path, mode, on_open: nil)
      file = primary = nil
      begin
        boundary do
          file = File.open(path, mode, 0o600)
          on_open&.call
        end
        check_open(file, path)
        yield file
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        cleanup(primary, 'handle') { file.close if file && !file.closed? }
      end
    end

    # Pochodzenie dotyczy tylko bieżącego chronionego odczytu katalogu.
    def guard
      @guard.call
    rescue Exception => error
      @read_provenance[:guard_error] ||= error if @read_provenance
      raise error, cause: error.cause
    end

    def boundary
      guard
      primary = nil
      begin
        yield
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          guard
        ensure
          raise primary, cause: primary.cause if primary
        end
      end
    end

    def cleanup(primary, phase)
      completed = false
      begin
        yield
        completed = true
      rescue Exception => error
        raise error, cause: error.cause unless primary
      ensure
        begin
          unless completed
            @diagnostics = (@diagnostics.last(3) + [{
              'attempt_id' => @attempt_id, 'phase' => phase.freeze, 'failure' => 'cleanup_failed'.freeze
            }.freeze]).freeze
          end
        ensure
          raise primary, cause: primary.cause if primary
        end
      end
    end

    def bounded(document)
      Data.copy(document, max_bytes: MAX_BYTES, max_nodes: 524_288, max_depth: 20)
    rescue Invalid => error
      raise unless error.code == :json_budget
      raise Invalid.new(:sandbox_limit), cause: error
    end

    def path_stat(path)
      boundary do
        begin
          File.lstat(path)
        rescue Errno::ENOENT
          nil
        end
      end
    end

    def check_paths
      directory = @directory
      loop do
        stat = path_stat(directory)
        raise Invalid, :unsafe_sandbox if stat && (stat.symlink? || !stat.directory?)
        parent = File.dirname(directory)
        break if parent == directory
        directory = parent
      end
      [@path, @path + '.lock'].each do |path|
        stat = path_stat(path)
        raise Invalid, :unsafe_sandbox if stat && (stat.symlink? || !stat.file? || stat.nlink != 1)
      end
    end

    def check_open(file, path)
      stat = boundary { file.stat }
      unless stat.file? && stat.nlink == 1 && boundary { File.identical?(file, path) }
        raise Invalid, :unsafe_sandbox
      end
    end

    def read_document
      return nil unless path_stat(@path)
      bytes = resource(@path, File::RDONLY | File::BINARY) { |file| boundary { file.read(MAX_BYTES + 1) } }
      raise Invalid, :sandbox_limit if bytes.bytesize > MAX_BYTES
      value = begin
        bounded(StrictJson.parse(bytes, max_nesting: 20))
      rescue JSON::ParserError, EncodingError => error
        raise Invalid.new(:sandbox_corrupt), cause: error
      end
      raise Invalid, :sandbox_corrupt unless value.is_a?(Hash)
      value
    end
  end
end
