require_relative 'tournament_marker'

# A durable, ordered assertion made by the current host client. Native receipt
# times authenticate the messages, not the players' absence. No local timer or
# unknown interval after an outage/host change is reconstructed as evidence.
module GameRoomTournamentPresence
  LIMIT_MS = 300_000
  CHECKPOINT_SECONDS = 15.0
  module_function

  def data(session:, fixture:, binding_digest:, absent:, elapsed_ms:, loser: nil, mode: nil, origin: 'host')
    value = {'version'=>1, 'previous'=>session.fetch('__game_boundary', ''),
      'epoch'=>session.fetch('__control_epoch', 'initial'), 'fixture'=>GameRoomTournamentMarker.copy(fixture),
      'binding_digest'=>binding_digest, 'absent'=>absent, 'elapsed_ms'=>elapsed_ms, 'loser'=>loser}
    if mode || origin != 'host' || session.dig('__tournament_presence', 'version') == 2
      value.merge!('version'=>2, 'mode'=>mode || (loser && 'terminal'), 'origin'=>origin,
        'revision'=>session.fetch('__game_revision', ''))
    end
    prior = session['__tournament_presence']
    totals = totals_after(session['__players'], prior, elapsed_ms)
    remaining = active_players(session['__players'], prior) - (mode == 'continue' ? [loser] : [])
    terminal = loser && mode != 'continue'
    {'session_id'=>session['__id'], 'frozen'=>!(absent & remaining).empty? || !!terminal || ambiguous?(totals.slice(*remaining)), 'tournament_presence'=>value}.tap do |result|
      result['aborted'] = true if terminal
    end
  end

  def transition(data, players:, fixture:, previous:, boundary_id:, epoch:, revision: '')
    value = data['tournament_presence']
    return nil unless value.is_a?(Hash) && [1, 2].include?(value['version'])
    fields = %w[absent binding_digest elapsed_ms epoch fixture loser previous version]
    fields += %w[mode origin revision] if value['version'] == 2
    return nil unless value.keys.sort == fields.sort && value['epoch'] == epoch && value['previous'] == boundary_id.to_s
    return nil if value['version'] == 2 && (!value['revision'].is_a?(String) || value['revision'] != revision)
    return nil unless value['fixture'] == GameRoomTournamentMarker.copy(fixture)
    digest = value['binding_digest']
    return nil unless digest.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(digest)
    return nil if previous && (terminal?(previous) || previous['binding_digest'] != digest)
    active = active_players(players, previous)
    absent, elapsed = value.values_at('absent', 'elapsed_ms')
    return nil unless absent.is_a?(Array) && absent == active.select { |player| absent.include?(player) }
    return nil unless elapsed.is_a?(Integer) && elapsed.between?(0, LIMIT_MS)
    prior_absent = previous ? previous['absent'] : []
    return nil if elapsed.positive? && (prior_absent.empty? || previous['epoch'] != epoch)
    totals = totals_after(players, previous, elapsed)
    loser = value['loser']
    mode = value['version'] == 1 ? (loser && 'terminal') : value['mode']
    origin = value.fetch('origin', 'host')
    return nil unless %w[host organizer].include?(origin) && [nil, 'continue', 'terminal'].include?(mode)
    return nil unless loser.nil? == mode.nil?
    return nil if origin == 'organizer' && (mode != 'continue' || elapsed != 0)
    if loser
      return nil unless active.include?(loser) && active.size >= 2
      return nil if value['version'] == 1 && active.size != 2
      return nil if mode == 'continue' && active.size <= 2
      return nil if origin == 'host' && (absent != [loser] || totals[loser] != LIMIT_MS || ambiguous?(totals.slice(*active)))
    end
    groups = (previous && previous['eliminations'] || []).map(&:dup)
    groups << [loser] if mode == 'continue'
    remaining = active - (mode == 'continue' ? [loser] : [])
    effective_absent = absent & remaining
    terminal = mode == 'terminal'
    return nil unless data['frozen'] == (!effective_absent.empty? || terminal || ambiguous?(totals.slice(*remaining))) &&
      data.key?('aborted') == terminal && (!terminal || data['aborted'] == true)
    return nil unless (data.keys - %w[session_id frozen aborted tournament_presence]).empty?
    value.merge('totals_ms'=>totals, 'absent'=>effective_absent, 'eliminations'=>groups)
  rescue GameRoomTournamentMarker::Invalid
    nil
  end

  def totals_after(players, previous, elapsed)
    players.to_h do |player|
      total = previous ? previous['totals_ms'].fetch(player) : 0
      total += elapsed if previous && previous['absent'].include?(player)
      [player, [total, LIMIT_MS].min]
    end
  end

  def ambiguous?(totals)
    totals.values.count { |value| value >= LIMIT_MS } > 1
  end

  def active_players(players, presence)
    players - (presence && presence['eliminations'] || []).flatten
  end

  def terminal?(presence)
    presence && presence['loser'] && presence.fetch('mode', 'terminal') == 'terminal'
  end

  def ended?(session)
    session['__authority_validated'] == true && session['__aborted'] == true &&
      session['__tournament_presence'].is_a?(Hash) && terminal?(session['__tournament_presence'])
  end
end
