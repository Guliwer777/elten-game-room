# frozen_string_literal: true
require 'fileutils'
require 'tmpdir'

module GameRoomTest
  # Keep test evidence in the ignored workspace directory, without depending
  # on another scenario (or an earlier local run) to create its parent.
  module TemporaryDirectory
    ROOT = File.expand_path('../..', __dir__)

    def self.create(prefix, root: ROOT, &block)
      parent = File.join(root, 'tmp')
      FileUtils.mkdir_p(parent)
      Dir.mktmpdir(prefix, parent, &block)
    end
  end
end
