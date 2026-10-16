# encoding: UTF-8
require_relative 'tournament_readiness_fixture'
module TournamentReadinessFixture
  # Wyłącznie w testach: awarie na nazwanych granicach rzeczywistego pliku.
  class FaultService < GameRoomTournaments::ReadinessService
    attr_accessor :fault
    private
    def boundary(cleanup:false, &block)
      location=block.source_location
      @lines ||= {}
      lines=(@lines[location[0]] ||= File.readlines(location[0]))
      text=lines[location[1]-1]
      matches=@fault && text.include?(@fault[:text]) && !cleanup
      @fault[:seen]=(@fault[:seen] || 0)+1 if matches
      hit=matches && @fault[:seen]==@fault[:nth]
      super(cleanup:cleanup) do
        raise IOError,'Testowa awaria przed I/O' if hit && @fault[:when]==:before
        value=block.call
        raise IOError,'Testowa awaria po I/O' if hit && @fault[:when]==:after
        value
      end
    end
  end
end
