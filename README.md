<img src="/logo.svg" width="64px" height="64px"/>

[![EO principles respected here](https://www.elegantobjects.org/badge.svg)](https://www.elegantobjects.org)
[![DevOps By Rultor.com](http://www.rultor.com/b/yegor256/futex)](http://www.rultor.com/p/yegor256/futex)
[![We recommend RubyMine](https://www.elegantobjects.org/rubymine.svg)](https://www.jetbrains.com/ruby/)

[![Build Status](https://travis-ci.org/yegor256/futex.svg)](https://travis-ci.org/yegor256/futex)
[![Build status](https://ci.appveyor.com/api/projects/status/po1mn8ca96jk0llr?svg=true)](https://ci.appveyor.com/project/yegor256/futex)
[![Gem Version](https://badge.fury.io/rb/futex.svg)](http://badge.fury.io/rb/futex)
[![Maintainability](https://api.codeclimate.com/v1/badges/5528e182bb5e4a2ecc1f/maintainability)](https://codeclimate.com/github/yegor256/futex/maintainability)
[![Yard Docs](http://img.shields.io/badge/yard-docs-blue.svg)](http://rubydoc.info/github/yegor256/futex/master/frames)

[![Hits-of-Code](https://hitsofcode.com/github/yegor256/futex)](https://hitsofcode.com/view/github/yegor256/futex)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/yegor256/futex/blob/master/LICENSE.txt)

Sometimes you need to synchronize your block of code, but `Mutex` is too coarse-grained,
because it _always locks_, no matter what objects your code accesses. The
`Futex` (from "file mutex") is more fine-grained and uses a file as an
entrance lock to your code.

First, install it:

```bash
$ gem install futex
```

Then, use it like this:

```ruby
require 'futex'
Futex.new('/tmp/my-file.txt').open do |f|
  IO.write(f, 'Hello, world!')
end
```

The file `/tmp/my-file.txt.lock` will be created and used as an entrance lock.
It <del>will</del> [won't](https://github.com/yegor256/futex/issues/5) be deleted afterwards.

If you are not planning to write to the file, it is recommended to get
a non-exclusive/shared access to it, by providing `false` to the method
`open()`:

```ruby
require 'futex'
Futex.new('/tmp/my-file.txt').open(false) do |f|
  IO.read(f)
end
```

For better traceability you can provide a few arguments to the
constructor of the `Futex` class, including:

  * `log`: an object that implements `debug()` method, which will
    receive supplementary messages from the locking mechanism;

  * `logging`: set it to `true` if you want to see logs;

  * `timeout`: the number of seconds to wait for the lock availability
    (`Futex::CantLock` exception is raised when the wait is expired);

  * `sleep`: the number of seconds to wait between attempts to acquire
    the lock file (the smaller the number, the more responsive is the software,
    but the higher the load for the file system and the CPU);

  * `lock`: the absolute path of the lock file;

That's it.

## How to contribute

Read [these guidelines](https://www.yegor256.com/2014/04/15/github-guidelines.html).
Make sure you build is green before you contribute
your pull request. You will need to have [Ruby](https://www.ruby-lang.org/en/) 2.3+ and
[Bundler](https://bundler.io/) installed. Then:

```
$ bundle update
$ bundle exec rake
```

If it's clean and you don't see any error messages, submit your pull request.
