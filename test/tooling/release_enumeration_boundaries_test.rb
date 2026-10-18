require 'tmpdir'
require_relative '../../tools/support/release_files'

def assert(value, message)
  raise message unless value
end

RUNTIME_ROOTS = %w[games lib content Audio locale LICENSES].freeze
EXTRA_FILES = %w[games/nested/game.rb lib/extra.rb content/nested/data.rb Audio/notice.opus].freeze

def source_fixture(container, redirect: {})
  source = File.join(container, 'source')
  Dir.mkdir(source)
  files = (GameRoomReleaseFiles::REQUIRED_FILES + EXTRA_FILES).sort
  files.each do |relative|
    root, tail = relative.split('/', 2)
    path = redirect.key?(root) ? File.join(redirect.fetch(root), tail) : File.join(source, relative)
    FileUtils.mkdir_p(File.dirname(path))
    contents = case relative
               when 'manifest.json' then '{"required_assets":{"sounds":["notice"]}}'
               when '__app.rb' then "require_relative 'lib/extra'\n"
               when 'Audio/notice.opus' then "OggS\x00\xFFOpusHeadfixture".b
               else "# own fixture: #{relative}\n"
               end
    File.binwrite(path, contents)
  end
  [source, files]
end

def assert_selection(source, expected, label)
  actual = GameRoomReleaseFiles.files(source)
  assert(actual == expected, "#{label}: unexpected selection #{actual.inspect}")
  assert(actual.frozen?, "#{label}: selection is not frozen")
end

def assert_missing_root(source, expected, root, label)
  retained = expected.reject { |path| path.start_with?("#{root}/") }
  missing = GameRoomReleaseFiles::REQUIRED_FILES - retained
  if !missing.empty? || root == 'Audio'
    message = missing.empty? ? 'Required sound must have exactly one file: notice' : "Missing release files: #{missing.join(', ')}"
    begin
      GameRoomReleaseFiles.files(source)
    rescue RuntimeError => error
      assert(error.message == message, "#{label}: wrong rejection: #{error.message}")
      return
    end
    raise "#{label}: required root was accepted"
  end
  assert_selection(source, retained, label)
end

def with_directory_link(target, link)
  assert(!File.exist?(link) && !File.symlink?(link), 'Link destination already exists')
  expected = File.realpath(target)
  created = false
  if File::ALT_SEPARATOR == '\\'
    output, status = Open3.capture2e({'GR_ENUMERATION_LINK_TARGET' => target, 'GR_ENUMERATION_LINK_PATH' => link},
      'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
      'New-Item -ItemType Junction -Path $env:GR_ENUMERATION_LINK_PATH -Target $env:GR_ENUMERATION_LINK_TARGET -ErrorAction Stop | Out-Null')
    assert(status.success?, "Cannot create own junction fixture: #{output}")
  else
    File.symlink(target, link)
  end
  created = true
  assert(File.symlink?(link) && File.realpath(link) == expected, 'Fixture is not the requested directory link')
  yield
ensure
  if created
    assert(File.symlink?(link) && File.realpath(link) == expected, 'Own link identity changed before cleanup')
    File.unlink(link)
    assert(!File.symlink?(link) && !File.exist?(link), 'Own directory link was not removed')
    assert(File.directory?(expected), 'Removing the link removed its target')
  end
end

cases = 0
Dir.mktmpdir('gr-enumeration-boundaries-') do |directory|
  GameRoomReleaseFiles::ROOT_FILES.each_with_index do |relative, index|
    container = File.join(directory, "root-case-#{index}")
    Dir.mkdir(container)
    source, expected = source_fixture(container)
    assert_selection(source, expected, relative)
    alternative = relative.swapcase
    File.rename(File.join(source, relative), File.join(source, 'case-intermediate'))
    File.rename(File.join(source, 'case-intermediate'), File.join(source, alternative))
    assert(Dir.children(source).include?(alternative) && !Dir.children(source).include?(relative), 'Root case was not actually changed')
    begin
      GameRoomReleaseFiles.files(source)
      raise "Incorrect required root casing accepted: #{relative}"
    rescue RuntimeError => error
      assert(error.message == "Missing release files: #{relative}", "Wrong root-file rejection: #{error.message}")
    end
    File.rename(File.join(source, alternative), File.join(source, 'case-intermediate'))
    File.rename(File.join(source, 'case-intermediate'), File.join(source, relative))
    assert_selection(source, expected, "restored #{relative}")
    cases += 1
  end

  RUNTIME_ROOTS.each_with_index do |root, index|
    container = File.join(directory, "directory-case-#{index}")
    Dir.mkdir(container)
    source, expected = source_fixture(container)
    alternative = root.swapcase
    original = File.join(source, root)
    renamed = File.join(source, alternative)
    intermediate = File.join(source, 'case-intermediate')
    assert([original, renamed, intermediate].all? { |path| File.dirname(File.expand_path(path)) == File.realpath(source) }, 'Rename escaped own fixture')
    File.rename(original, intermediate)
    File.rename(intermediate, renamed)
    assert(Dir.children(source).include?(alternative) && !Dir.children(source).include?(root), 'Directory case was not actually changed')
    assert_missing_root(source, expected, root, "wrong-case #{root}")
    File.rename(renamed, intermediate)
    File.rename(intermediate, original)
    assert_selection(source, expected, "restored #{root}")
    cases += 1
  end

  RUNTIME_ROOTS.product(%w[inside outside]).each_with_index do |(root, location), index|
    container = File.join(directory, "root-link-#{index}")
    Dir.mkdir(container)
    target = File.join(container, location == 'inside' ? 'source/private-fixture' : 'outside-fixture')
    source, expected = source_fixture(container, redirect: {root => target})
    with_directory_link(target, File.join(source, root)) do
      assert_missing_root(source, expected, root, "#{root} link #{location} source")
      next unless root == 'games'
      retained = expected.reject { |path| path.start_with?('games/') }
      destination = File.join(container, 'stage')
      assert(GameRoomReleaseFiles.stage(source, destination) == retained, 'Root link changed staging selection')
      retained.each do |path|
        assert(File.binread(File.join(source, path)) == File.binread(File.join(destination, path)), 'Staging changed retained bytes')
      end
    end
    cases += 1
  end

  %w[inside outside].each_with_index do |location, index|
    container = File.join(directory, "nested-link-#{index}")
    Dir.mkdir(container)
    source, expected = source_fixture(container)
    target = File.join(container, location == 'inside' ? 'source/private-fixture' : 'outside-fixture')
    Dir.mkdir(target)
    File.write(File.join(target, 'not-shipped.rb'), '# own linked fixture')
    with_directory_link(target, File.join(source, 'games/linked')) do
      assert_selection(source, expected, "nested link #{location} source")
    end
    assert_selection(source, expected, "nested link cleanup #{location}")
    cases += 1
  end
end
puts "PASS release enumeration boundaries: #{cases} actual root-case and directory-link fixtures; exact exclusions, required-file failures and staged bytes"
