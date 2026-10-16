require_relative 'local_fixed_team_dispatcher'
require_relative 'local_dispatch_runtime'
module GameRoomTournaments
  module LocalDispatchConnection
    def plan_dispatch_configure(intent_id:, max_tables:)
      dispatcher.configure(intent_id: intent_id, max_tables: max_tables,consent_before_table:true)
    end
    def plan_dispatch_ensure_configured(intent_id:, max_tables:)
      dispatcher.snapshot(intent_id: intent_id)
    rescue CoordinationContract::Blocked => error
      raise unless error.code == :dispatch_not_configured
      dispatcher.configure(intent_id: intent_id, max_tables: max_tables,consent_before_table:true)
    end
    def perform(action:, selectors:, **options)
      if @dispatch_intent && @dispatch_intent != selectors[:intent_id]
        @dispatch_runtime&.close
        @dispatch_runtime = @dispatch_intent = nil
      end
      return super unless %i[dispatch_enable dispatch_disable dispatch_accept dispatch_decline dispatch_rematch dispatch_not_now dispatch_renew dispatch_configure].include?(action)
      intent = selectors.fetch(:intent_id)
      effect = case action
      when :dispatch_configure
        dispatcher.configure(intent_id: intent, max_tables: options.fetch(:max_tables),consent_before_table:true)
        {state: :confirmed, status: dispatcher.snapshot(intent_id: intent)}
      when :dispatch_enable
        dispatcher.available(intent_id: intent, available: true)
        @dispatch_runtime&.close
        @dispatch_runtime = LocalDispatchRuntime.new(dispatcher: dispatcher, intent_id: intent,
          identity: @backend.identity, runtime: @program_runtime)
        @dispatch_intent = intent
        {state: :enabled, status: dispatcher.snapshot(intent_id: intent)}
      when :dispatch_disable
        dispatcher.available(intent_id: intent, available: false)
        @dispatch_runtime&.close
        @dispatch_runtime = nil
        @dispatch_intent = nil
        {state: :disabled, status: dispatcher.snapshot(intent_id: intent)}
      when :dispatch_accept
        dispatcher.accept(intent_id: intent,expected_proposal:options[:proposal_token],require_expected:true)
      when :dispatch_decline
        dispatcher.decline(intent_id:intent,expected_proposal:options[:proposal_token],require_expected:true)
      when :dispatch_rematch
        dispatcher.accept(intent_id:intent,rematch_only:true,expected_proposal:options[:proposal_token],require_expected:true)
      when :dispatch_not_now
        dispatcher.decline(intent_id:intent,rematch_only:true,expected_proposal:options[:proposal_token],require_expected:true)
      when :dispatch_renew
        dispatcher.renew_expired(intent_id: intent)
      end
      {state: :read, selection: selectors, dispatch: effect}.freeze
    rescue CoordinationContract::Blocked, ReadinessContract::Blocked => error
      {state: :read, selection: selectors, dispatch: {state: :blocked, reason: error.code}}.freeze
    end
    def initialize(program:, **options)
      @program_runtime = program.class.app_runtime
      super(program: program, **options)
    end
    def dispatch_update; @dispatch_runtime&.update; end
    def close(primary: nil)
      @dispatch_runtime&.close
    ensure
      super(primary: primary)
    end
    private
    def dispatcher
      @dispatcher ||= dispatcher_class.new(**@options, expires_at: nil)
    end
    def dispatcher_class; LocalFixedTeamDispatcher; end
  end
end
