# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
results = []
[:actor, :backend].each do |mode|
  context, service, reference = fixture
  source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
  with_backend(context) do |backend, _, session, authority, directory|
    input = {publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'aba'}
    shown = backend.preview(**input)
    before = authority.call
    original = context.provider.method(:select_rows)
    fired = false
    context.provider.define_singleton_method(:select_rows) do |*args, **kwargs|
      value = original.call(*args, **kwargs)
      unless fired
        fired = true
        if mode == :actor
          session.choose_actor('InnaOsoba')
          session.choose_actor('Organizator')
        else
          session.change_backend('inny-backend')
          session.change_backend(backend.identity)
        end
      end
      value
    end
    # Bramka zachowuje pierwotną odmowę swojego post-guardu; serwis jej nie maskuje.
    error = assert_raises(T::TablesGateway::ContextChanged) { backend.accept(preview: shown) }
    assert_equal(:context_changed, error.cause.code)
    assert(!File.exist?(File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')))
    after = authority.call
    assert(after['cancelled'] && before['account'] == after['account'])
    results << {'mode' => mode, 'before' => before, 'after' => after, 'code' => error.cause.code}
  end
end
context, service, reference = fixture
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
action = nil
reader = -> { action&.call; 'WlascicielPlikow' }
with_backend(context, reader: reader) do |backend, build, _, _, directory|
  shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'wyjatki')
  record = backend.accept(preview: shown)
  path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
  bytes = File.binread(path)
  [EncodingError.new('Kodowanie czytnika'), Errno::ENOENT.new('Czytnik, nie brak pliku'), RuntimeError.new('Błąd callbacka')].each do |primary|
    cause = RuntimeError.new('Bezpośrednia przyczyna')
    begin
      raise primary, cause: cause
    rescue Exception => captured
      primary = captured
    end
    primary.set_backtrace(['zaufany_czytnik.rb:77'])
    fired = false
    original = File.method(:lstat)
    File.define_singleton_method(:lstat) do |name|
      result = original.call(name)
      if name == path && !fired
        fired = true
        action = -> { raise primary, cause: primary.cause }
      end
      result
    end
    begin
      returned = assert_raises(primary.class) { backend.readback(intent_id: 'wyjatki') }
      assert(returned.equal?(primary))
      assert(returned.cause.equal?(cause))
      assert_equal(['zaufany_czytnik.rb:77'], returned.backtrace)
    ensure
      action = nil
      File.define_singleton_method(:lstat, original)
    end
    assert_equal(record, build.call.readback(intent_id: 'wyjatki'))
    assert_equal(bytes, File.binread(path))
    results << {'primary' => returned.class.name, 'message' => returned.message, 'cause' => returned.cause.message, 'backtrace' => returned.backtrace}
  end
  action = -> { throw :przerwanie, :zachowane }
  assert_equal(:zachowane, catch(:przerwanie) { backend.readback(intent_id: 'wyjatki') })
  action = nil
  assert_equal(record, build.call.readback(intent_id: 'wyjatki'))
  assert_equal(bytes, File.binread(path))
  # Wejście caller zmieniane przez worker katalogu pozostaje odłączone.
  entered, release = Queue.new, Queue.new
  original = context.provider.method(:select_rows)
  once = false
  context.provider.define_singleton_method(:select_rows) do |*args, **kwargs|
    unless once
      once = true
      entered << true
      release.pop
    end
    original.call(*args, **kwargs)
  end
  mutable_members, mutable_base, mutable_ref, mutable_template = membership, bases(source), reference.dup.transform_values(&:dup), TEMPLATE.dup
  worker = Thread.new do
    backend.preview(publication_ref: mutable_ref, membership: mutable_members, team_template: mutable_template, base_seats: mutable_base, intent_id: 'watek')
  end
  Timeout.timeout(5) { entered.pop }
  mutable_members['units'].clear
  mutable_base.clear
  mutable_ref['author'].replace('Intruz')
  mutable_template.clear
  release << true
  observed = worker.value
  assert_equal(membership, observed['membership'])
  assert_equal(bases(source), observed['base_seats'])
  assert_equal(TEMPLATE, observed['team_template'])
  results << {'detached_preview' => observed, 'worker_joined' => !worker.alive?}
end
oracle_file('oracle.json', results)
puts 'FT1: prawdziwe epoki ABA, primary/cause/backtrace/throw i mutacja wątku — OK'
