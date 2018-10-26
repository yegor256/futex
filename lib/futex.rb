# frozen_string_literal: true

# (The MIT License)
#
# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'fileutils'
require 'time'

# Futex.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
class Futex
  def initialize(path, log: STDOUT, timeout: 30, sleep: 0.005,
    lock: path + '.lock')
    raise "File path can't be nil" if path.nil?
    @path = path
    raise "Log can't be nil" if log.nil?
    @log = log
    raise "Timeout can't be nil" if timeout.nil?
    raise "Timeout can't be negative or zero: #{timeout}" unless timeout.positive?
    @timeout = timeout
    raise "Sleep can't be nil" if sleep.nil?
    raise "Sleep can't be negative or zero: #{sleep}" unless sleep.positive?
    @sleep = sleep
    raise "Lock path can't be nil" if lock.nil?
    @lock = lock
  end

  def open
    FileUtils.mkdir_p(File.dirname(@path))
    step = (1 / @sleep).to_i
    res = File.open(@lock, File::RDWR | File::CREAT) do |f|
      start = Time.now
      cycle = 0
      loop do
        break if f.flock(File::LOCK_EX | File::LOCK_NB)
        sleep(@sleep)
        cycle += 1
        if Time.now - start > @timeout
          raise "##{Process.pid}/#{Thread.current.name} can't get \
exclusive access to the file #{@path} \
because of the lock at #{f.path}, after #{age(start)} of waiting: #{f.read}"
        end
        if (cycle % step).zero? && Time.now - start > @timeout / 2
          debug("##{Process.pid}/#{Thread.current.name} still waiting for \
exclusive access to #{@path}, #{age(start)} already: #{f.read}")
        end
      end
      debug("Locked by \"#{Thread.current.name}\" in #{age(start)}: #{@path} \
(attempt no.#{cycle})")
      f.write("##{Process.pid}/#{Thread.current.name}")
      acq = Time.now
      yield(@path)
      puts("Unlocked by \"#{Thread.current.name}\" in #{age(acq)}: #{@path}")
      FileUtils.rm(@lock)
    end
    res
  end

  private

  def age(time)
    "#{((Time.now - time) * 1000).round}ms"
  end

  def debug(msg)
    if @log.respond_to?(:debug)
      @log.debug(msg)
    elsif @log.respond_to?(:puts)
      @log.puts(msg)
    end
  end
end
