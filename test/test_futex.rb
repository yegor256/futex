# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2018-2026 Yegor Bugayenko
# SPDX-License-Identifier: MIT

require 'digest'
require 'minitest/autorun'
require 'securerandom'
require 'threads'
require 'tmpdir'
require_relative '../lib/futex'

# Futex test.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018-2026 Yegor Bugayenko
# License:: MIT
class FutexTest < Minitest::Test
  def test_syncs_access_to_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a/b/c/file.txt')
      Threads.new(2).assert do |_, r|
        Futex.new(path, logging: true).open do |f|
          text = "op no.#{r}"
          File.write(f, text)
          assert_equal(text, File.read(f))
        end
      end
    end
  end

  def test_syncs_read_only_access_to_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'file.txt')
      text = 'Hello, world!'
      File.write(path, text)
      Threads.new(2).assert do
        Futex.new(path).open(false) do |f|
          assert_equal(text, File.read(f))
        end
      end
    end
  end

  def test_syncs_access_to_file_in_slow_motion
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a/b/c/file.txt')
      Threads.new(20).assert(200) do |_, r|
        Futex.new(path).open do |f|
          text = "op no.#{r}"
          File.write(f, text)
          sleep(0.01)
          assert_equal(text, File.read(f))
        end
      end
    end
  end

  def test_raises_if_cant_lock
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'the/simple/file.txt')
      Thread.start do
        Futex.new(path).open do
          sleep(10)
        end
      end
      sleep(2)
      ex =
        assert_raises(Futex::CantLock) do
          Futex.new(path, timeout: 0.1).open do |_f|
            nil
          end
        end
      assert_includes(ex.message, "can't get exclusive access to the file", ex)
      assert_operator(ex.start, :<, Time.now - 1)
    end
  end

  def test_exclusive_and_shared_locking
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'g/e/f/file.txt')
      Threads.new(20).assert(1000) do |_, r|
        if (r % 50).zero?
          Futex.new(path).open do |f|
            text = SecureRandom.hex(1024)
            hash = hash(text)
            File.write(f, "#{text} #{hash}")
          end
        end
        Futex.new(path).open(false) do |f|
          if File.exist?(f)
            text, hash = File.read(f, text).split
            assert_equal(hash, hash(text))
          end
        end
      end
    end
  end

  def test_exclusive_and_shared_locking_in_processes
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'g/e/f/file.txt')
      10.times do
        Process.fork do
          Threads.new(20).assert(1000) do |_, r|
            if (r % 50).zero?
              Futex.new(path).open do |f|
                text = SecureRandom.hex(1024)
                hash = hash(text)
                File.write(f, "#{text} #{hash}")
              end
            end
            Futex.new(path).open(false) do |f|
              if File.exist?(f)
                text, hash = File.read(f, text).split
                assert_equal(hash, hash(text))
              end
            end
          end
          exit!(0)
        end
      end
      Process.waitall.each do |p, e|
        raise(StandardError, "Failed in PID ##{p}: #{e}") unless e.exitstatus.zero?
      end
    end
  end

  def test_cleans_up_the_mess
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        File.write(f, 'hey')
        FileUtils.rm(f)
      end
      assert_equal(2, Dir.new(dir).count)
    end
  end

  def test_sets_thread_vars
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        assert_equal("#{f}.lock", Thread.current.thread_variable_get(:futex_lock))
        assert_includes(Thread.current.thread_variable_get(:futex_badge), '-ex/nil')
      end
    end
  end

  def test_removes_thread_vars
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |_f|
        nil
      end
      assert_nil(Thread.current.thread_variable_get(:futex_lock))
    end
  end

  def test_saves_calling_file_name_in_lock
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        badge = File.read("#{f}.lock")
        assert_includes(badge, 'test/test_futex.rb:', badge)
      end
    end
  end

  def test_works_without_block_given
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open
    end
  end

  def test_works_with_broken_counts_file
    File.write(Futex::COUNTS, 'fds')
    Dir.mktmpdir do |dir|
      Futex.new(File.join(dir, 'hey.txt')).open do |f|
        refute_path_exists(f)
      end
    end
  end

  private

  def hash(text)
    Digest::SHA256.hexdigest(text)
  end
end
