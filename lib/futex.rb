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

# Futex.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
class Futex
  def initialize(path, log: STDOUT, timeout: 30)
    @path = path
    @log = log
    @timeout = timeout
  end

  def open
    FileUtils.mkdir_p(File.dirname(@path))
    lock = @path + '.lock'
    acq = nil
    res = File.open(lock, File::RDWR | File::CREAT) do |f|
      start = Time.now
      cycles = 0
      loop do
        break if f.flock(File::LOCK_EX | File::LOCK_NB)
        sleep 0.001
        cycles += 1
        if Time.now - start > @timeout
          raise "##{Process.pid}/#{Thread.current.name} can't get \
exclusive access to the file #{@path} \
because of the lock at #{f.path}, after #{age(start)} of waiting: #{f.read}"
        end
        if (cycles % 1000).zero? && Time.now - start > 10
          debug("##{Process.pid}/#{Thread.current.name} still waiting for \
exclusive access to #{@path}, #{age(start)} already: #{f.read}")
        end
      end
      debug("Locked by \"#{Thread.current.name}\" in #{age(start)}: #{@path}")
      f.write("##{Process.pid}/#{Thread.current.name}")
      acq = Time.now
      yield @path
    end
    puts("Unlocked by \"#{Thread.current.name}\" in #{age(acq)}: #{@path}")
    FileUtils.rm_rf(lock)
    res
  end

  private

  def age(time)
    "#{((Time.now - time) * 1000).round}ms"
  end

  def debug(msg)
    return if @log.nil?
    if @log.respond_to?(:debug)
      @log.debug(msg)
    elsif @log.respond_to?(:puts)
      @log.puts(msg)
    end
  end
end
