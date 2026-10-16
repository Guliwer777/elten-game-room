require_relative 'server_phase_plan'
require_relative 'server_plan_archive'

module GameRoomTournaments
  # Any registered participant can publish the deterministic next phase.
  # Every reader reconstructs the full lineage from fresh verified results.
  class ServerPhaseStore
    MAX_PHASES=256
    Data=Publication::Data
    def initialize(table:,journal:,user:,source:,results:,guard:-> {true})
      @table,@journal,@user,@source,@results,@guard=table,journal,user,source,results,guard
      @owner=journal.owner
      @changed=false
    end
    def current
      root=root!
      candidate=root.fetch('candidate')
      finished=false
      history=[]
      MAX_PHASES.times do
        retained=anchor(root,candidate)
        entries=rows(retained, root)
        if entries.empty?
          finished=true
          break
        end
        view=@results.call(candidate,root)
        expected=ServerPhasePlan.build(candidate:candidate,results:view['results'])
        stored=ServerPlanDocument.confirmed_copy(entries,anchor:retained,authors:authors(root),expected:expected)
        raise Publication::Invalid,:phase_changed unless stored==expected
        display=candidate.slice('schedule_id','format','groups','membership','matches')
        display['knockout']=candidate['knockout'].slice('round','seeds','players_per_match') if candidate['knockout']
        display['knockout']['qualification']=true if candidate.dig('knockout','qualification')
        history << {'candidate'=>display,'view'=>{'standings'=>view['standings'],
          'results'=>view['results'].map{|receipt|receipt.slice('kind','match_id','leg','summary')}}}
        history.last['view']['progress_times']=view['progress_times'] if view['progress_times']
        raise Publication::Invalid,:phase_read_limit if JSON.generate(history).bytesize>1_048_576
        candidate=stored.fetch('candidate')
        root_same!(root)
        raise Publication::Invalid,:phase_read_limit if candidate==root['candidate']
      end
      # A bounded traversal must never silently present an intermediate phase.
      raise Publication::Invalid,:phase_read_limit unless finished
      root_same!(root)
      value=root.merge('candidate'=>candidate)
      value['phase_history']=history unless history.empty?
      Data.freeze_tree(value)
    end

    # Pure key calculation for a batched directory read; it carries no phase
    # evidence or authority. current still verifies every published phase.
    def first_document_key(root)
      anchor(root,root.fetch('candidate')).fetch('operation_key')
    end
    def advance(expected_schedule_id:)
      source=current
      parent=source.fetch('candidate')
      raise Publication::Invalid,:phase_changed unless parent['schedule_id']==expected_schedule_id
      root=root!
      raise Publication::Invalid,:not_registered unless authors(root).include?(@owner)
      document=ServerPhasePlan.build(candidate:parent,results:@results.call(parent,root)['results'])
      retained=anchor(root,parent)
      archive(parent,root).publish(intent_id:'server-sporting-phase-v1:'+retained['operation_key'],document:document,anchor:retained)
      current
    end
    def reconcile(id)
      check!
      record=@journal.fetch(id)
      raise OperationJournal::Invalid,:missing_plan_operation unless record
      document=StrictJson.parse(record['values']['document_json'],max_nesting:12)
      root=root!
      parent=find_parent(root,document['parent_schedule_id'])
      archive(parent,root).resume(id)
    end
    private
    def find_parent(root,wanted)
      parent=root.fetch('candidate')
      MAX_PHASES.times do
        return parent if parent['schedule_id']==wanted
        retained=anchor(root,parent)
        entries=rows(retained, root)
        raise Publication::Invalid,:phase_changed if entries.empty?
        expected=ServerPhasePlan.build(candidate:parent,results:@results.call(parent,root)['results'])
        document=ServerPlanDocument.confirmed_copy(entries,anchor:retained,authors:authors(root),expected:expected)
        parent=document.fetch('candidate')
      end
      raise Publication::Invalid,:phase_read_limit
    end
    def archive(parent,root)
      ServerPlanArchive.new(table:@table,journal:@journal,user:-> {check!;@user.call},verify:->(document,retained) do
        root_same!(root)
        expected=ServerPhasePlan.build(candidate:parent,results:@results.call(parent,root)['results'])
        retained==anchor(root,parent) && document==expected && authors(root).include?(@owner)
      end)
    end
    def anchor(root,candidate)
      {'operation_key'=>ServerPhasePlan.digest(['server-sporting-phase-v1',@journal.backend_identity,root['tournament_id'],candidate['schedule_id']]),
        'tournament_id'=>root['tournament_id'],'publication_digest'=>candidate['publication_digest'],'roster_generation'=>candidate['roster_generation']}
    end
    def authors(root)
      (root['candidate']['roster'] + [root['candidate']['publication_ref']['author']]).uniq
    end
    def rows(retained, root)
      trusted = authors(root)
      ServerDocumentRows.read(@table,where:{'operation_key'=>retained['operation_key']},guard:method(:check!)).select do |row|
        trusted.include?(row['__insertion_user'].to_s.downcase)
      end
    end
    def root!
      check!
      source=@source.call
      check!
      candidate=source.fetch('candidate').reject{|key,_|key=='observed_at'}
      Data.freeze_tree(Data.copy(source.merge('candidate'=>candidate),max_bytes:262144,max_nodes:16384,max_depth:16))
    end
    def root_same!(root)
      raise Publication::Invalid,:source_changed unless root==root!
    end
    def check!
      value=Data.account(@user.call).downcase
      @changed=true unless value==@owner
      raise ServerPlanArchive::ContextChanged,'Account changed' if @changed
      raise TablesGateway::Cancelled,'View changed' unless @guard.call
    end
  end
end
