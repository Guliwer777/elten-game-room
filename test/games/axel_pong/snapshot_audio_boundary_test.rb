require_relative '../../support/pong_client'
require_relative '../../support/pong_audio'

# The packet originates in the real host snapshot. Only the indicated field
# changes before Protocol -> Client -> observer frame -> real Audio.
failures = []
cases = 0
[false, true].each do |doubles|
  options = doubles ? {team_size: 2, team_seats: [0, 0, 1, 1]}.transform_keys(&:to_s) : {}
  players = doubles ? %w[Alice Bob Carol Dave] : %w[Alice Bob]
  variants = %w[serve hit shield_on shield_off shield_hit].flat_map do |effect|
    [[effect, 0, true], [effect, nil, false]]
  end
  variants += %w[wall invisible step edge goal].map { |effect| [effect, nil, true] }
  variants += ['teams_integer', 'teams_hash', 'teams_string', 'teams_wrong'].map { |kind| [kind, 0, false] }
  variants << ['teams_nil', 0, !doubles]
  variants.each do |kind, side, expected|
    h = PongHarness.new(players: players, options: options)
    begin
      h.advance(doubles ? 550 : 220)
      observer = h.clients.fetch('Watcher')
      audio = GameRoomPong::Audio.new(PongAudioProgram.new, clock: -> { h.now })
      audio.load
      observer.instance_variable_set(:@audio, audio)
      packet = JSON.parse(h.network.fetch('alice').sent.last)
      packet['n'] += 1000
      state = packet.fetch('d').fetch('state')
      state['fx'] = [[10_000, kind.start_with?('teams_') ? 'hit' : kind, side, 15, 0]]
      case kind
      when 'teams_integer' then state['teams'] = 123
      when 'teams_hash' then state['teams'] = {'0' => 0}
      when 'teams_string' then state['teams'] = '01'
      when 'teams_wrong' then state['teams'] = doubles ? [1, 1, 0, 0] : [0, 0, 1, 1]
      when 'teams_nil' then state['teams'] = nil
      end
      channel = h.network.fetch('watcher')
      decoded = GameRoomRealtime::Protocol.decode(JSON.generate(packet), match: channel.match, epoch: channel.epoch)
      assert(decoded, 'Packet did not reach the application validator')
      admitted = observer.send(:valid_state?, decoded.fetch('d'))
      before = Marshal.dump(observer.snapshot)
      channel.inbox['alice'] = decoded
      error = nil
      begin
        observer.frame
      rescue StandardError => exception
        error = "#{exception.class}: #{exception.message}"
      end
      label = "#{doubles ? 'doubles' : 'single'} #{kind}/#{side.inspect}"
      failures << "#{label}: validation #{admitted.inspect}, expected #{expected}" unless admitted == expected
      failures << "#{label}: #{error}" if error
      if expected
        failures << "#{label}: valid snapshot not presented" unless observer.snapshot == decoded['d']['state']
      else
        failures << "#{label}: invalid snapshot replaced current state" unless Marshal.dump(observer.snapshot) == before
      end
      cases += 1
    ensure
      h.close
    end
  end
end
assert(failures.empty?, failures.join("\n"))
puts "PASS Pong snapshot audio boundary: #{cases} real packet/frame cases, valid nil wall/invisible and doubles rotation preserved"
