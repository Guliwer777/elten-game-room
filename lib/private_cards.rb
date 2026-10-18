require 'json'
require 'securerandom'
require_relative 'game_event_protocol'

# The pool receipt comes from the native SDK, never from a player's packet.
# A take publishes its count, not its values. Only a reveal publishes a card.
module GameRoomPrivateCards
  VERSION = 1
  MAX_POOLS = 32
  Command = Struct.new(:action, :value, :pool_request, keyword_init: true)
  @games = {}
  @sharing = {}
  module_function

  def register(game, host: [], claim: [], take: [], reveal: [], random: [], player_random: [], deals: ['deal'], ordered: false, payload: false, retain_unrevealed_draws: false, host_payload_actions: [])
    @games[game.to_s] = {host: host.freeze, claim: claim.freeze, take: take.freeze,
      reveal: (reveal + ['private_show']).uniq.freeze, random: random.freeze, player_random: player_random.freeze,
      deals: deals.freeze, ordered: ordered, payload: payload, retain_unrevealed_draws: retain_unrevealed_draws,
      host_payload_actions: host_payload_actions.freeze}.freeze
  end
  def supported?(game); @games.key?(game.to_s); end
  def register_sharing(game, &projection); @sharing[game.to_s] = projection; end
  def sharing_projection(game); @sharing[game.to_s]; end
  def retain_unrevealed_draws?(game); @games.fetch(game.to_s, {})[:retain_unrevealed_draws] == true; end
  def random_required?(game); !@games.fetch(game.to_s, {}).fetch(:random, []).empty?; end
  def ordered?(game); @games.fetch(game.to_s, {})[:ordered] == true; end
  def payload?(game); @games.fetch(game.to_s, {})[:payload] == true; end
  def enabled?(session); session['__private_cards'] == VERSION; end
  def deal_action?(game, action); @games.fetch(game.to_s, {}).fetch(:deals, []).include?(action); end

  def player_random?(game, request)
    @games.fetch(game.to_s, {}).fetch(:player_random, []).include?(request.dig('recipe', 'data', 'action'))
  end

  def valid_action?(game, action, controlled:, host:, pool:, random:)
    contract = @games[game.to_s]
    return false unless contract
    if random
      return !pool && contract[:random].include?(action) &&
        (host || (!controlled && player_random?(game, random)))
    end
    return host && !pool if contract[:host].include?(action)
    return false if controlled
    return !pool if contract[:claim].include?(action)
    return pool && pool['operation'] == 'take' if contract[:take].include?(action)
    # An already disclosed/transferred card no longer needs a native reveal.
    # The model must still prove public ownership before accepting that claim.
    return !pool || pool['operation'] == 'reveal' if contract[:reveal].include?(action)
    false
  end

  def command(action, value = '', **request)
    Command.new(action: action, value: value, pool_request: request.transform_keys(&:to_s))
  end

  def valid_commands?(game, commands, controlled:, host:, pool:, random:)
    if controlled && host && payload?(game) && !pool && !random && commands.all? { |command| command['action'] == game.to_s }
      data = GameRoomActionPayload.data_from_commands(commands, game.to_s)
      return data && @games.fetch(game.to_s).fetch(:host_payload_actions).include?(data['action'])
    end
    if commands.length != 1
      return false unless payload?(game) && !pool &&
        commands.all? { |command| command['action'] == game.to_s } &&
        GameRoomActionPayload.data_from_commands(commands, game.to_s)
    end
    valid_action?(game, commands.first['action'], controlled: controlled, host: host, pool: pool, random: random)
  end

  def request_from(events)
    requests = events.filter_map { |event| GameRoomEventProtocol.command_value(event, 'pool_request') }
    return nil if requests.empty?
    claims = requests.length == events.length && requests.all? { |request| request == {'operation'=>'claim'} }
    raise ArgumentError, 'A private card move must be one operation' unless claims || (events.length == 1 && requests.length == 1)
    request = JSON.parse(JSON.generate(requests.first))
    raise ArgumentError, 'Invalid private card request' unless valid_request?(request)
    request
  end

  def pool_id?(value)
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]{16,64}\z/)
  end

  def valid_request?(request)
    return false unless request.is_a?(Hash)
    case request['operation']
    when 'claim'
      request.keys == ['operation']
    when 'create', 'check'
      return false unless request['size'].is_a?(Integer) && request['size'].positive?
      if request['operation'] == 'create'
        request.keys.sort == %w[operation retire size] && request['retire'].is_a?(Array) &&
          request['retire'].length <= MAX_POOLS && request['retire'].all? { |id| pool_id?(id) }
      else
        request.keys.sort == %w[operation pool_id size] && pool_id?(request['pool_id'])
      end
    when 'take'
      (request.keys.sort == %w[count operation pool_id] ||
        (request.keys.sort == %w[count operation pool_id visibility] && request['visibility'] == 'public')) &&
        pool_id?(request['pool_id']) && request['count'].is_a?(Integer) && request['count'].between?(1, 100)
    when 'reveal'
      [ %w[draw_id operation pool_id value], %w[draw_id operation pool_id values] ].include?(request.keys.sort) && pool_id?(request['pool_id']) &&
        request['draw_id'].is_a?(String) && request['draw_id'].bytesize.between?(1, 128) &&
        valid_reveal_values?(reveal_values(request))
    else
      false
    end
  end

  def reveal_values(request)
    request.key?('values') ? request['values'] : [request['value']]
  end

  def valid_reveal_values?(values)
    values.is_a?(Array) && values.length.between?(1, 100) && values.uniq.length == values.length &&
      values.all? { |value| value.is_a?(Integer) && value.positive? }
  end

  def native_operation(metadata)
    if metadata.respond_to?(:server_pool?)
      return nil unless metadata.server_pool? && !metadata.private?
      [metadata.operation.to_s, metadata.pool_id]
    elsif metadata.is_a?(Hash) && metadata['origin'] == 'server_pool' &&
        [nil, 'public'].include?(metadata['visibility']) && metadata['pool'].is_a?(Hash)
      metadata['pool'].values_at('operation', 'id')
    end
  end

  def context(packet)
    data = packet.fetch('data')
    event = data.fetch('events').fetch(0)
    value = {'pgp' => VERSION, 's' => data.fetch('session_id'), 'q' => data.fetch('sequence'),
     'e' => data.fetch('control_epoch'), 'a' => event.fetch('action'), 'v' => event.fetch('value')}
    value['b'] = data['presence_boundary'] if data.key?('presence_boundary')
    raise ArgumentError, 'Private card context exceeds the server limit' if JSON.generate(value).bytesize > 256
    value
  end

  def decode(packet, metadata, sender:, message_id:)
    native = native_operation(metadata)
    return [packet, nil] unless native
    operation, pool_id = native
    return nil unless %w[take reveal].include?(operation) && packet.is_a?(Hash) && packet['pool_id'] == pool_id
    context = packet['context']
    return nil unless context.is_a?(Hash) && [%w[a e pgp q s v], %w[a b e pgp q s v]].include?(context.keys.sort) &&
      context['pgp'] == VERSION && context['s'].is_a?(Integer) && context['s'].positive? &&
      context['q'].is_a?(Integer) && context['q'] >= 0 && context['e'].is_a?(String) &&
      context['a'].is_a?(String) && context['v'].is_a?(String)
    return nil if context.key?('b') && !(context['b'].is_a?(String) && context['b'].bytesize <= 64)
    return nil unless packet['draw_id'].is_a?(String)
    valid = if operation == 'take'
      packet['count'].is_a?(Integer) && packet['count'].between?(1, 100) &&
        packet['remaining'].is_a?(Integer) && packet['remaining'] >= 0 &&
        ((packet['visibility'] == 'private' && !packet.key?('values')) ||
         (packet['visibility'] == 'public' && packet['values'].is_a?(Array) &&
          packet['values'].length == packet['count'] && packet['values'].uniq.length == packet['count'] &&
          packet['values'].all? { |value| value.is_a?(Integer) && value.positive? }))
    else
      valid_reveal_values?(packet['values'])
    end
    return nil unless valid
    event = {'action' => context['a'], 'value' => context['v'], 'move_id' => message_id.to_s}
    return nil unless GameRoomEventProtocol.valid_wire_commands?([event])
    canonical = GameRoomEventProtocol.game_action_packet(session_id: context['s'], sequence: context['q'],
      control_epoch: context['e'], events: [event], actor: sender.to_s)
    canonical['data']['presence_boundary'] = context['b'] if context.key?('b')
    keys = operation == 'take' ? %w[pool_id draw_id count remaining visibility values] : %w[pool_id draw_id values]
    proof = JSON.parse(JSON.generate(packet.slice(*keys))).merge('operation' => operation)
    [canonical, proof]
  end
end
