# encoding: UTF-8
require_relative 'readiness_request'
require_relative 'local_filesystem'
require 'fileutils'
require 'securerandom'
require 'thread'

module GameRoomTournaments
  # Osobna tożsamość intencji przeżywa niepewny pierwszy rename dziennika.
  class ReadinessJournal
    C = ReadinessContract
    MAX_BYTES = 2_097_152
    MAX_RECORDS = 128
    TERMINAL = %w[confirmed refused conflict].freeze
    class Corrupt < StandardError
      attr_reader :operation
      def initialize(message, operation:nil)
        @operation=operation
        super(message)
      end
    end
    class Busy < StandardError; end
    class Uncertain < StandardError; end
    attr_reader :path

    def initialize(directory:, scope:, match_ref:, account:, io:)
      C.text!(directory)
      raise C::Invalid, :invalid_directory if directory.tr('\\','/').start_with?('//') || directory.match?(/\A[A-Za-z]:(?![\\\/])/)
      C.target!(scope,match_ref)
      C.text!(account)
      @identity=C.frozen_copy({'scope'=>scope,'match_ref'=>match_ref,'account'=>account})
      @directory=File.join(File.expand_path(directory),'readiness-v1',C.digest(@identity))
      @path=File.join(@directory,'state.json')
      @io, @mutex, @held = io, Mutex.new, false
    end

    def with_attempt
      raise Busy, 'Próba zajęta' unless @mutex.try_lock
      lock=nil; primary=nil
      begin
        check_directory
        disk { FileUtils.mkdir_p(LocalFilesystem.native(@directory),mode:0o700) }
        check_directory
        lock_path=File.join(@directory,'attempt.lock')
        check_file(lock_path)
        disk { lock=File.open(LocalFilesystem.native(lock_path),File::RDWR|File::CREAT,0o600) }
        check_open(lock,lock_path)
        raise Busy, 'Próba zajęta' unless disk { lock.flock(File::LOCK_EX|File::LOCK_NB) }
        @held=true
        yield self
      rescue Exception => error
        primary=error
        raise
      ensure
        begin
          @io.call(cleanup:true) { lock.close } if lock && !lock.closed?
        ensure
          @held=false
          @mutex.unlock
          raise primary, cause:primary.cause if primary
        end
      end
    end

    def records
      raise Busy, 'Brak blokady dziennika' unless @held
      check_directory
      names=disk { Dir.children(LocalFilesystem.native(@directory)) }
      raise Corrupt, 'Limit plików dziennika' if names.size>MAX_RECORDS*4+2
      names.each { |name| check_file(File.join(@directory,name)) }
      anchors=names.select { |name| name.end_with?('.intent') }.sort.map do |name|
        document=read_json(File.join(@directory,name))
        validate_intent(document,name)
      end
      raise Corrupt, 'Limit intencji' if anchors.size>MAX_RECORDS
      raise Corrupt, 'Powtórzony UUID' unless anchors.map { |op| op['operation_id'] }.uniq.size==anchors.size
      # Niepewny albo częściowy zapis obserwacji nigdy nie jest pustym dowodem.
      anchors.each do |op|
        if names.include?(slot(op)+'.observed.tmp')
          raise Corrupt.new('Nieukończona obserwacja',operation:op)
        end
      end
      raise Corrupt, 'Osierocona nieukończona obserwacja' if names.any? { |name| name.end_with?('.observed.tmp') }
      known=anchors.map { |op| slot(op)+'.observed' }
      raise Corrupt, 'Osierocona obserwacja' unless (names.grep(/\.observed\z/)-known).empty?
      observations=anchors.to_h { |op| [op['operation_id'],observed(op)] }
      document=read_json(@path)
      validate_records(document,anchors,observations)
    end

    def claim(operation)
      list=records.map(&:dup)
      raise C::Blocked, :intent_conflict if list.any? { |r| slot(r['operation'])==slot(operation) }
      raise C::Blocked, :unresolved_operation if list.any? { |r| !TERMINAL.include?(r['status']) }
      raise C::Blocked, :journal_limit if list.size>=MAX_RECORDS
      validate_scope(C.operation!(operation))
      # EXCL jest nieusuwalnym zatrzaskiem, również gdy pierwszy rename zawiedzie.
      write_file(File.join(@directory,slot(operation)+'.intent'),JSON.generate(operation))
      list << {'operation'=>operation,'status'=>'prepared','evidence'=>nil}
      write_state(list)
      list.last['status']='attempted'
      write_state(list)
      true
    end

    # Obserwacja nie jest potwierdzeniem: dopiero zgodny lookup może rozstrzygnąć próbę.
    def observed(operation)
      raise Busy, 'Brak blokady dziennika' unless @held
      response=read_json(File.join(@directory,slot(operation)+'.observed'))
      return nil unless response
      begin
        response=C.response!(response,operation)
      rescue C::Invalid, C::Blocked, C::PortUnavailable
        raise Corrupt, 'Uszkodzony dziennik gotowości'
      end
      raise Corrupt, 'Nieterminalna obserwacja' unless TERMINAL.include?(response['status'])
      response
    end

    def observe(operation, response)
      response=C.response!(response,operation)
      raise C::Invalid, :nonterminal_receipt unless TERMINAL.include?(response['status'])
      record=records.find { |r| r['operation'].eql?(operation) }
      raise Corrupt, 'Brak pierwotnej operacji' unless record
      prior=observed(operation) || record['evidence']
      if prior
        raise C::Blocked, :receipt_conflict unless prior.eql?(response)
        return
      end
      path=File.join(@directory,slot(operation)+'.observed')
      temporary=path+'.tmp'
      write_file(temporary,JSON.generate(response))
      check_directory
      check_file(path)
      disk { File.rename(LocalFilesystem.native(temporary),LocalFilesystem.native(path)) }
    end

    def resolve(operation, response)
      raise C::Invalid, :nonterminal_receipt unless TERMINAL.include?(response['status'])
      C.response!(response,operation)
      list=records.map(&:dup)
      record=list.find { |r| r['operation'].eql?(operation) }
      raise Corrupt, 'Brak pierwotnej operacji' unless record
      if record['evidence']
        raise C::Blocked, :receipt_conflict unless record['evidence'].eql?(response)
        return
      end
      record['status']=response['status']; record['evidence']=response
      write_state(list)
    end

    private

    # Wyłącznie walidacja odłączonych dokumentów; I/O i jego guard pozostają poza rescue.
    def validate_intent(document,name)
      op=C.operation!(document)
      validate_scope(op)
      raise Corrupt, 'Błędny slot intencji' unless name.eql?(slot(op)+'.intent')
      op
    rescue C::Invalid, C::Blocked, C::PortUnavailable
      raise Corrupt, 'Uszkodzony dziennik gotowości'
    end

    def validate_records(document,anchors,observations)
      saved=[]
      if document
        C.fields!(document,%w[version identity records])
        unless document['version'].eql?(1) && document['identity'].eql?(@identity) && document['records'].is_a?(Array) && document['records'].size<=MAX_RECORDS
          raise Corrupt, 'Niezgodny dziennik'
        end
        saved=document['records']
      end
      ids=[]
      saved.each do |record|
        C.fields!(record,%w[operation status evidence])
        op=C.operation!(record['operation'])
        raise Corrupt, 'Brak intencji lub duplikat' unless anchors.include?(op) && !ids.include?(op['operation_id'])
        ids << op['operation_id']
        if TERMINAL.include?(record['status'])
          answer=C.response!(record['evidence'],op)
          raise Corrupt, 'Błędny dowód końcowy' unless answer['status'].eql?(record['status'])
          observed=observations[op['operation_id']]
          if observed && !observed.eql?(answer)
            raise Corrupt.new('Sprzeczne dowody końcowe',operation:op)
          end
        elsif %w[prepared attempted].include?(record['status'])
          raise Corrupt, 'Niepoprawny dowód próby' unless record['evidence'].nil?
        else
          raise Corrupt, 'Nieznany stan próby'
        end
      end
      C::Data.freeze_tree(anchors.map do |op|
        saved.find { |r| r['operation'].eql?(op) } || {'operation'=>op,'status'=>'prepared','evidence'=>nil}
      end)
    rescue C::Invalid, C::Blocked, C::PortUnavailable
      raise Corrupt, 'Uszkodzony dziennik gotowości'
    end

    def slot(op)
      C.digest(op['request']['expected_ready_revision'])
    end

    def validate_scope(op)
      value={'scope'=>op['request']['scope'],'match_ref'=>op['request']['match_ref'],'account'=>op['account']}
      raise Corrupt, 'Niezgodny zakres intencji' unless value.eql?(@identity)
    end

    def disk(&block)
      @io.call(&block)
    rescue IOError, SystemCallError => error
      raise Uncertain, 'Niepewne lokalne I/O', cause:error
    end

    def stat(path)
      disk do
        begin
          File.lstat(LocalFilesystem.native(path))
        rescue Errno::ENOENT
          nil
        end
      end
    end

    def check_directory
      path=@directory
      loop do
        value=stat(path)
        raise Corrupt, 'Niebezpieczny katalog' if value && (value.symlink? || !value.directory?)
        parent=File.dirname(path)
        break if parent==path
        path=parent
      end
    end

    def check_file(path)
      value=stat(path)
      raise Corrupt, 'Niebezpieczny plik' if value && (value.symlink? || !value.file? || value.nlink!=1)
    end

    def check_open(file,path)
      check_file(path)
      value=disk { file.stat }
      raise Corrupt, 'Niebezpieczny uchwyt' unless value.file? && value.nlink==1 && disk { File.identical?(file,LocalFilesystem.native(path)) }
    end

    def read_json(path)
      check_file(path)
      return nil unless stat(path)
      bytes=disk { File.binread(LocalFilesystem.native(path),MAX_BYTES+1) }
      raise Corrupt, 'Pusty dokument dziennika' unless bytes.is_a?(String)
      raise Corrupt, 'Limit bajtów' if bytes.bytesize>MAX_BYTES
      bytes.force_encoding(Encoding::UTF_8)
      raise Corrupt, 'Błędny UTF-8' unless bytes.valid_encoding?
      begin
        value=StrictJson.parse(bytes,max_nesting:24)
      rescue JSON::ParserError
        raise Corrupt, 'Uszkodzony dziennik gotowości'
      end
      raise Corrupt, 'Korzeń dokumentu nie jest obiektem' unless value.is_a?(Hash)
      value
    end

    def write_file(path, bytes)
      raise Corrupt, 'Limit bajtów' if bytes.bytesize>MAX_BYTES
      file=nil; primary=nil
      begin
        disk { file=File.open(LocalFilesystem.native(path),File::WRONLY|File::CREAT|File::EXCL,0o600) }
        check_open(file,path)
        disk { file.binmode }
        raise Uncertain, 'Niepełny zapis' unless disk { file.write(bytes) }.eql?(bytes.bytesize)
        disk { file.flush }
        disk { file.fsync }
        disk { file.close }
      rescue Exception => error
        primary=error
        raise
      ensure
        begin
          @io.call(cleanup:true) { file.close } if file && !file.closed?
        ensure
          raise primary, cause:primary.cause if primary
        end
      end
    end

    def write_state(records)
      document={'version'=>1,'identity'=>@identity,'records'=>records}
      temporary=@path+'.tmp-'+SecureRandom.hex(12)
      write_file(temporary,JSON.generate(document))
      check_directory
      check_file(@path)
      disk { File.rename(LocalFilesystem.native(temporary),LocalFilesystem.native(@path)) }
    end
  end
end
