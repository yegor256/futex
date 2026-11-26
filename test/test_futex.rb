# frozen_string_literal: true

# SPDX-FileCopyrightText: Copyright (c) 2018-2026 Yegor Bugayenko
# SPDX-License-Identifier: MIT

require 'English'
require 'digest'
require 'etc'
require 'json'
require 'minitest/autorun'
require 'rbconfig'
require 'securerandom'
require 'threads'
require 'tmpdir'
require_relative '../lib/futex'

# Futex test.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018-2026 Yegor Bugayenko
# License:: MIT
class FutexTest < Minitest::Test
  CHILD_CODE = <<~'RUBY'
    require 'tmpdir'
    require 'futex'
    File.umask(0o022)
    target = ENV.fetch('TARGET')
    Futex.new(target).open do |f|
      File.write(f, "written by #{Process.uid}")
      raise 'wrong content' unless File.read(f) == "written by #{Process.uid}"
    end
    puts 'OK'
  RUBY

  PAUSER_CODE = <<~RUBY
    class File
      alias_method :chmod_right_away, :chmod

      def chmod(mode)
        $stderr.puts 'paused'
        $stderr.flush
        $stdin.read
        chmod_right_away(mode)
      end
    end
  RUBY

  SUDO = '/usr/bin/sudo'
  USERADD = %w[/usr/sbin/useradd /sbin/useradd].find { |path| File.executable?(path) }

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
          Futex.new(path, timeout: 0.1).open
        end
      assert_includes(ex.message, "can't get exclusive access to the file", ex)
      assert_operator(ex.start, :<, Time.now - 1)
    end
  end

  def test_waits_with_integer_sleep_above_one_second
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a/b/file.txt')
      holder, acquired, release = hold(path)
      contender = nil
      begin
        acquired.pop
        assert_raises(Futex::CantLock) do
          Futex.new(path, sleep: 2, timeout: 5).open
        end
        outcome = Queue.new
        contender =
          Thread.start do
            begin
              Futex.new(path, sleep: 2, timeout: 10).open do |f|
                File.write(f, 'done')
              end
              outcome << :acquired
            rescue StandardError => e
              outcome << e
            end
          end
        release << true
        assert_equal(:acquired, outcome.pop)
        assert_equal('done', File.read(path))
      ensure
        release << true
        reap(holder, contender)
      end
    end
  end

  def test_raises_if_cant_lock_with_big_sleep
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a/b/file.txt')
      holder, acquired, release = hold(path)
      begin
        acquired.pop
        ex =
          assert_raises(Futex::CantLock) do
            Futex.new(path, sleep: 1.5, timeout: 2).open
          end
        assert_includes(ex.message, "can't get exclusive access to the file", ex)
      ensure
        release << true
        reap(holder)
      end
    end
  end

  def test_rejects_non_positive_sleep
    Dir.mktmpdir do |dir|
      [0, -1, -0.5].each do |s|
        ex =
          assert_raises(ArgumentError) do
            Futex.new(File.join(dir, 'file.txt'), sleep: s)
          end
        assert_includes(ex.message, "sleep must be a positive number, but #{s.inspect} given", ex)
      end
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
      Futex.new(File.join(dir, 'hey.txt')).open
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

  def test_two_users_share_the_counts_file
    skip('needs root or passwordless sudo to run as other users') unless switchable?
    sandbox do |dir|
      purge
      runner(666_001, 'owner', dir)
      runner(666_002, 'guest', dir)
      assert_equal({}, JSON.parse(File.read(Futex::COUNTS)))
      assert_equal(0o666, File.stat(Futex::COUNTS).mode & 0o777)
    end
  end

  def test_migrates_counts_file_left_by_older_version
    skip('needs root or passwordless sudo to run as other users') unless switchable?
    sandbox do |dir|
      purge
      File.write(Futex::COUNTS, '{}')
      FileUtils.chmod(0o644, Futex::COUNTS)
      privileged('chown', '666001:666001', Futex::COUNTS)
      runner(666_001, 'owner', dir)
      assert_equal(0o666, File.stat(Futex::COUNTS).mode & 0o777)
      runner(666_002, 'guest', dir)
      assert_equal({}, JSON.parse(File.read(Futex::COUNTS)))
    end
  end

  def test_opens_counts_file_owned_by_another_user
    skip('needs root or passwordless sudo to run as other users') unless switchable?
    sandbox do |dir|
      purge
      File.write(Futex::COUNTS, '{}')
      FileUtils.chmod(0o666, Futex::COUNTS)
      privileged('chown', '666001:666001', Futex::COUNTS)
      runner(666_002, 'guest', dir)
      assert_equal({}, JSON.parse(File.read(Futex::COUNTS)))
    end
  end

  def test_opens_counts_file_being_created
    skip('needs root or passwordless sudo to run as other users') unless switchable?
    sandbox do |dir|
      purge
      creator = launch(666_001, 'owner', dir, PAUSER_CODE + CHILD_CODE)
      begin
        assert_equal("paused\n", creator[:err].gets, 'the owner must stop before its chmod')
        await(launch(666_002, 'guest', dir))
        await(creator)
      ensure
        finish(creator)
      end
      stat = File.stat(Futex::COUNTS)
      assert_equal([666_002, 0o666], [stat.uid, stat.mode & 0o777], 'the guest must publish the ready counter')
      assert_equal({}, JSON.parse(File.read(Futex::COUNTS)))
    end
  end

  private

  def purge
    privileged('rm', '-f', Futex::COUNTS)
  end

  def runner(uid, name, dir)
    await(launch(uid, name, dir))
  end

  # Starts the given Ruby +code+ on behalf of the user with the given +uid+,
  # in a home directory of its own inside +dir+, and returns the child with
  # the pipes connected to its stdin, stdout and stderr.
  def launch(uid, name, dir, code = CHILD_CODE)
    home = File.join(dir, name)
    privileged('install', '-d', '-o', uid.to_s, '-g', uid.to_s, '-m', '700', home)
    script = File.join(dir, "#{name}.rb")
    File.write(script, code)
    FileUtils.chmod(0o644, script)
    child = { name: name }
    stdin, child[:in] = IO.pipe
    child[:out], stdout = IO.pipe
    child[:err], stderr = IO.pipe
    child[:pid] = Process.spawn(*command(uid, home, script, chdir: '/tmp', in: stdin, out: stdout, err: stderr))
    [stdin, stdout, stderr].each(&:close)
    child
  end

  # Builds the command line to run the +script+ on behalf of the user with
  # the given +uid+: with a plain Ruby (not the Bundler of this suite) when
  # root, otherwise through sudo, which resets the environment.
  def command(uid, home, script, opts)
    ruby = [RbConfig.ruby, '-I', File.join(File.dirname(script), 'lib'), script]
    env = { 'TARGET' => File.join(home, 'x.txt'), 'TMPDIR' => Dir.tmpdir }
    if root?
      [
        env.merge('RUBYOPT' => nil, 'BUNDLER_SETUP' => nil),
        *ruby, opts.merge(uid: uid, gid: uid)
      ]
    else
      [
        SUDO, '-n', '-u', login(uid, home), '/usr/bin/env',
        *env.map { |key, value| "#{key}=#{value}" }, *ruby, opts
      ]
    end
  end

  # Closes stdin of the child (letting it go), waits for its exit and
  # collects everything it printed; repeated calls do nothing.
  def finish(child)
    return if child[:status]
    child[:in].close
    child[:out] = child[:out].read
    child[:err] = child[:err].read
    Process.wait(child[:pid])
    child[:status] = $CHILD_STATUS
  end

  # Finishes the child and makes sure it did its job without complaints.
  def await(child)
    finish(child)
    raise(StandardError, "user #{child[:name]} failed: #{child[:out]}#{child[:err]}") unless child[:status].success?
    assert_equal("OK\n", child[:out])
  end

  # Returns the login to switch to with sudo for the given +uid+, registering
  # it first when the system doesn't know it yet.
  def login(uid, home)
    name = "futex#{uid}"
    num = uid.to_s
    begin
      name = Etc.getpwuid(uid).name
    rescue ArgumentError
      privileged('groupadd', '-f', '-g', num, name)
      privileged(USERADD, '-r', '-K', 'SYS_UID_MAX=700000', '-u', num, '-g', num, '-M', '-d', home, name)
      (@logins ||= []) << name
    end
    name
  end

  # Creates a temporary directory for other users to work in, with a copy of
  # the library (they may have no access to the sources of this suite), and
  # removes it afterwards with root privileges, since they leave files there.
  def sandbox
    dir = Dir.mktmpdir
    FileUtils.chmod(0o755, dir)
    FileUtils.cp_r(File.expand_path('../lib', __dir__), dir)
    FileUtils.chmod_R(0o755, File.join(dir, 'lib'))
    yield(dir)
  ensure
    if dir
      privileged('rm', '-rf', dir)
      Array(@logins).each { |name| system(SUDO, '-n', 'userdel', name, err: File::NULL) }
    end
  end

  # Runs a system command with root privileges: directly, when the suite
  # itself runs as root, otherwise through passwordless sudo.
  def privileged(*cmd)
    cmd = [SUDO, '-n', *cmd] unless root?
    raise(StandardError, "failed to run '#{cmd.join(' ')}'") unless system(*cmd)
  end

  # True when the suite can start processes on behalf of other users: it
  # either runs as root itself, or it can switch users with passwordless
  # sudo, like on GitHub Actions runners.
  def switchable?
    root? || (USERADD && File.executable?(SUDO) && system(SUDO, '-n', 'true', out: File::NULL, err: File::NULL))
  end

  def root?
    Process.uid.zero?
  end

  # Starts a background thread that acquires the lock at +path+ and keeps
  # it until something is pushed into the release queue. Returns the holder
  # thread together with two latches: the first one signals that the lock
  # has been acquired, the second one releases it.
  def hold(path)
    acquired = Queue.new
    release = Queue.new
    [
      Thread.start do
        Futex.new(path).open do
          acquired << true
          release.pop
        end
      end,
      acquired,
      release
    ]
  end

  # Joins every given thread (up to 15 seconds each) and kills those that
  # are still alive, so no thread outlives the test and keeps using files
  # that are about to be deleted by the temporary directory cleanup.
  def reap(*threads)
    threads.compact.each do |thread|
      thread.join(15)
      thread.kill if thread.alive?
    end
  end

  def hash(text)
    Digest::SHA256.hexdigest(text)
  end
end
