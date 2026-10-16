module GameRoomTournaments
  # Local revision observation only. The caller uses the existing task-backed
  # read path and applies the result without moving or announcing the focus.
  class ViewRefresh
    def initialize(program,reference:nil,&refresh)
      @program,@reference,@refresh=program,reference,refresh
      acknowledge
    end

    def acknowledge
      @seen=revision
    end

    def tick
      current=revision
      return if current==@seen
      @seen=current
      @refresh.call
    end

    private
    def revision
      @program.class.tournament_view_revision(@reference) if @program.class.respond_to?(:tournament_view_revision)
    end
  end
end
