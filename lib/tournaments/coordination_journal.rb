# encoding: UTF-8
require_relative 'coordination_contract'
require_relative 'local_filesystem'
require 'fileutils'
require 'securerandom'
require 'thread'

module GameRoomTournaments
  # Osobny format; nie dziedziczy OperationJournal i nie zmienia jego tabel.
  # LOCK_NB obejmuje CAŁĄ próbę. To wyłączność lokalna, nie globalny busy/CAS.
  class CoordinationJournal
    C = CoordinationContract
    Data = Publication::Data
    class Corrupt < StandardError; end
    class Busy < StandardError; end
    MAX_BYTES = 8_388_608
    attr_reader :path

    def initialize(directory:, scope:, account:, registry:, io:)
      Data.text!(directory,bytes:4096)
      raise C::Invalid, :invalid_directory if directory.tr('\\','/').start_with?('//') || directory.match?(/\A[A-Za-z]:(?![\\\/])/)
      @directory=File.join(File.expand_path(directory),'coordination-v1')
      @scope, @account = Data.freeze_tree(C.copy(scope)), account.dup.freeze
      @registry, @io, @mutex = registry, io, Mutex.new
      @path=File.join(@directory,"#{C.digest([scope,account])}.json")
      @held=false
    end

    def with_attempt
      raise Busy, 'Próba zajęta' unless @mutex.try_lock
      lock=nil
      primary=nil
      begin
        check_paths
        @io.call { FileUtils.mkdir_p(LocalFilesystem.native(@directory),mode:0o700) }
        check_paths
        @io.call { lock=File.open(LocalFilesystem.native(@path+'.lock'),File::RDWR|File::CREAT,0o600) }
        raise Busy, 'Próba zajęta' unless @io.call { lock.flock(File::LOCK_EX|File::LOCK_NB) }
        @held=true
        yield self
      rescue Exception => error
        primary=[error,error.cause,error.backtrace]
        raise
      ensure
        begin
          @io.call(cleanup:true) { lock.close } if lock
        ensure
          begin
            lock.close if lock && !lock.closed?
          ensure
            @held=false
            @mutex.unlock
            if primary
              primary[0].set_backtrace(primary[2])
              raise primary[0], cause:primary[1]
            end
          end
        end
      end
    end

    def records(request)
      read['operations'].select { |r| identity(r['operation']['request']).eql?(identity(request)) }
    end

    def claim(operation)
      document=read
      found=document['operations'].find { |r| r['operation']['kind']==operation['kind'] && identity(r['operation']['request']).eql?(identity(operation['request'])) }
      if found
        raise C::Blocked, :operation_conflict unless found['operation'].eql?(operation)
        return false
      end
      raise C::Invalid, :operation_limit if document['operations'].size >= 1024
      record={'status'=>'prepared','operation'=>C.copy(operation),'evidence'=>nil}
      document['operations'] << record
      # Najpierw niezmienna tożsamość, potem jednorazowe prawo attempted.
      # Niepewny drugi rename pozostawia co najmniej prepared: tylko lookup.
      write(document)
      record['status']='attempted'
      write(document)
      true
    end

    def confirm(operation, response)
      document=read
      record=document['operations'].find { |r| r['operation'].eql?(operation) }
      raise C::Blocked, :missing_operation unless record
      if record['evidence'] && !record['evidence'].eql?(response)
        raise C::Blocked, :receipt_conflict
      end
      return if record['evidence']
      record['status']='confirmed'; record['evidence']=C.copy(response)
      write(document)
    end

    private

    def identity(request)
      request.values_at('scope','match_id','leg','execution_generation')
    end

    def check_paths
      path=@directory
      loop do
        stat=@io.call do
          begin
            File.lstat(LocalFilesystem.native(path))
          rescue Errno::ENOENT
            nil
          end
        end
        raise Corrupt, 'Niebezpieczny katalog' if stat && (stat.symlink? || !stat.directory?)
        parent=File.dirname(path)
        break if parent==path
        path=parent
      end
      [@path,@path+'.lock'].each do |file|
        stat=@io.call do
          begin
            File.lstat(LocalFilesystem.native(file))
          rescue Errno::ENOENT
            nil
          end
        end
        raise Corrupt, 'Niebezpieczny plik' if stat && (stat.symlink? || !stat.file? || stat.nlink>1)
      end
    end

    def read
      raise Busy, 'Brak własności próby' unless @held
      check_paths
      bytes=@io.call do
        begin
          File.binread(LocalFilesystem.native(@path),MAX_BYTES+1)
        rescue Errno::ENOENT
          nil
        end
      end
      return {'schema_version'=>1,'scope'=>C.copy(@scope),'account'=>@account,'operations'=>[]} if bytes.nil?
      raise Corrupt, 'Limit dziennika' if bytes.bytesize>MAX_BYTES
      bytes.force_encoding(Encoding::UTF_8)
      raise Corrupt, 'Błędny UTF-8' unless bytes.valid_encoding?
      begin
        document=StrictJson.parse(bytes,max_nesting:24)
      rescue JSON::ParserError
        raise Corrupt, 'Uszkodzony dziennik'
      end
      begin
        validate(document)
      rescue C::Invalid, C::Blocked
        raise Corrupt, 'Uszkodzony dziennik'
      end
    end

    def validate(document)
      C.fields!(document,%w[schema_version scope account operations])
      unless document['schema_version'].eql?(1) && document['scope'].eql?(@scope) && document['account'].eql?(@account) &&
          document['operations'].is_a?(Array) && document['operations'].size<=1024
        raise Corrupt, 'Niezgodny zakres dziennika'
      end
      keys=[]; ids=[]
      document['operations'].each do |record|
        C.fields!(record,%w[status operation evidence])
        op=C.copy(record['operation'])
        C.operation!(op,registry:@registry)
        raise Corrupt, 'Niezgodny zakres operacji' unless op['request']['scope'].eql?(@scope)
        key=[identity(op['request']),op['kind']]
        raise Corrupt, 'Powtórzona operacja' if keys.include?(key) || ids.include?(op['operation_id'])
        keys << key; ids << op['operation_id']
        case record['status']
        when 'prepared', 'attempted'
          raise Corrupt, 'Niepoprawny dowód próby' unless record['evidence'].nil?
        when 'confirmed'
          raise Corrupt, 'Brak dowodu' unless record['evidence'].is_a?(Hash)
          response=C.response!(record['evidence'],op)
          raise Corrupt, 'Niepotwierdzony dowód' unless response['status']=='confirmed'
          if op['kind']=='create_bind'
            C.binding!(response,registry:@registry)
          else
            C.grant!(response['result'],op['request'],op['preconditions']['ready_versions'])
          end
        else
          raise Corrupt, 'Nieznany stan'
        end
      end
      document
    end

    def write(document)
      validate(document)
      bytes=JSON.generate(document)
      raise C::Invalid, :file_limit if bytes.bytesize>MAX_BYTES
      temporary=@path+'.tmp-'+SecureRandom.hex(12)
      file=nil
      begin
        @io.call { file=File.open(LocalFilesystem.native(temporary),File::WRONLY|File::CREAT|File::EXCL,0o600) }
        @io.call { file.binmode }
        raise IOError, 'Niepełny zapis' unless @io.call { file.write(bytes) }==bytes.bytesize
        @io.call { file.flush }
        @io.call { file.fsync }
        @io.call { file.close }
        file=nil
        check_paths
        @io.call { File.rename(LocalFilesystem.native(temporary),LocalFilesystem.native(@path)) }
      rescue Exception => error
        primary=[error,error.cause,error.backtrace]
        raise
      ensure
        # Własny temp pozostaje jako dowód; jego uchwyt zawsze jest zamykany.
        begin
          if file && !file.closed?
            begin
              @io.call(cleanup:true) { file.close }
            ensure
              file.close unless file.closed?
            end
          end
        ensure
          if primary
            primary[0].set_backtrace(primary[2])
            raise primary[0], cause:primary[1]
          end
        end
      end
    end
  end
end
