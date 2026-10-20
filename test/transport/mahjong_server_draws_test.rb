require_relative '../support/session_runner'
require_relative '../../games/mahjong'
require_relative '../support/contract_values'

class NoMahjongEntropy
  def roll(**); raise 'Mahjong attempted a local live deal'; end
end

def mahjong_native_snapshot(replay)
  snapshot = GameRoomTest::ReplaySnapshot::FIELDS.reject { |field| field == :accepted_events }.to_h { |field| [field, replay.public_send(field)] }
  if (board = snapshot[:state][:board])
    snapshot[:state] = snapshot[:state].merge(board: [board.positions, board.tiles, board.remaining])
  end
  GameRoomTest::ContractValues.digest(snapshot)
end

%w[solitaire hong_kong riichi mcr].each do |variant|
  game = GameRoomGames::Mahjong.new
  users = variant == 'solitaire' ? ['Alice'] : %w[Alice Bob Carol Dave]
  options = game.normalize_options('variant'=>variant)
  h = NativeRoomHarness.new(game: game, users: users, options: options)
  h.start
  context = GameRoomGames::ActionContext.new(session_id: h.session['__id'],
    random_source: NoMahjongEntropy.new, server_random: true)
  h.view('Alice').next_random_values = Array.new(16, 256)
  h.submit('Alice', context: context)
  assert(users.map { |user| h.events(user) }.uniq.length == 1, 'Clients disagree about native events')
  snapshots = users.map { |user| mahjong_native_snapshot(h.replay(user)) }
  assert(snapshots.uniq.length == 1, 'Clients disagree about Mahjong state')
  events = h.events('Alice')
  assert(events.length == 1 && h.replay('Alice').accepted_events.length == 1, 'Server deal rejected or duplicated')
  assert(h.view('Alice').calls[:random] == 1, 'Deal did not use one native draw')
  assert(events.first.dig('__server_random', 'recipe', 'kind') == 'seed_json', 'Missing native provenance')
  assert(JSON.parse(events.first['value'])['r'] == (1 << 63) - 1, 'Seed bounds changed')
  legacy = events.map { |event| event.reject { |key, _| key == '__server_random' } }
  archived = game.replay(h.session, legacy, h.repositories['Alice'])
  assert(mahjong_native_snapshot(archived) == mahjong_native_snapshot(h.replay('Alice')), 'Archive dialect changed')
  other = NativeRoomHarness.new(game: game, users: users, options: options)
  other.start
  before = other.core.entries.size
  rejected = false
  begin
    other.write('Alice', legacy)
  rescue ArgumentError => error
    rejected = error.message.include?('server draw')
  end
  assert(rejected && other.core.entries.size == before, 'Client-authored live shuffle accepted')
  if variant == 'solitaire'
    reordered = legacy.map { |event| event.merge('value'=>JSON.generate(JSON.parse(event['value']).to_a.reverse.to_h)) }
    rejected = false
    begin
      other.write('Alice', reordered)
    rescue ArgumentError => error
      rejected = error.message.include?('server draw')
    end
    assert(rejected && other.core.entries.size == before, 'Reordered JSON bypassed native draw protection')
  end
end

bad = [nil, {'r'=>1}, {'v'=>1, 'h'=>'not a safe value'}, {'v'=>1, 'h'=>10**60}]
bad.each do |data|
  assert(!GameRoomServerRandomRendering.valid?({'kind'=>'seed_json', 'data'=>data}), 'Malformed JSON seed recipe accepted')
end
puts 'PASS Mahjong server draws: four variants, native provenance, convergence, bounded seed, archive compatibility and forged packet rejection'
