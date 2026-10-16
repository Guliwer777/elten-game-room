# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'entry_context'
module GameRoomTournaments
  class TournamentWindow < Dialogs::Window
    def initialize(program:,workspace:,owner:)
      @program,@workspace,@owner=program,workspace,owner
    end
    def run
      return if @running || @finished
      primary=nil
      completed=false
      begin
        @context=EntryContext.new(program:@program,runtime:@program.class.app_runtime,
          owner_reader:@owner.method(:current),actor:@workspace.actor)
        @lease=@context.capture
        value=super
        completed=true
        value
      rescue Exception=>error
        primary=error
        raise error,cause:error.cause
      ensure
        @context&.close(primary:primary || (completed ? nil : :unwind))
      end
    end
    private
    def current?;@owner.check && @context && @context.current?(@lease);end
  end
end
