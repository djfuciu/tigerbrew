#!/usr/bin/ruby -W0
# -*- coding: utf-8 -*-

std_trap = trap("INT") { exit! 130 } # no backtrace thanks

HOMEBREW_BREW_FILE = ENV["HOMEBREW_BREW_FILE"]

if ARGV == %w[--prefix]
  puts File.dirname(File.dirname(HOMEBREW_BREW_FILE))
  exit 0
end

require "pathname"
HOMEBREW_LIBRARY_PATH = Pathname.new(__FILE__).realpath.parent.join("Homebrew")
$:.unshift(HOMEBREW_LIBRARY_PATH.to_s)
require "global"

if ARGV.first == "--version"
  puts Homebrew.homebrew_version_string
  exit 0
elsif ARGV.first == "-v"
  puts "Homebrew #{Homebrew.homebrew_version_string}"
  # Shift the -v to the end of the parameter list
  ARGV << ARGV.shift
  # If no other arguments, just quit here.
  exit 0 if ARGV.length == 1
end

# Check for bad xcode-select before anything else, because `doctor` and
# many other things will hang
# Note that this bug was fixed in 10.9
if OS.mac? && MacOS.version < :mavericks && MacOS.active_developer_dir == "/"
  odie <<-EOS.undent
  Your xcode-select path is currently set to '/'.
  This causes the `xcrun` tool to hang, and can render Homebrew unusable.
  If you are using Xcode, you should:
    sudo xcode-select -switch /Applications/Xcode.app
  Otherwise, you should:
    sudo rm -rf /usr/share/xcode-select
  EOS
end

case HOMEBREW_PREFIX.to_s
when "/", "/usr"
  # it may work, but I only see pain this route and don't want to support it
  abort "Cowardly refusing to continue at this prefix: #{HOMEBREW_PREFIX}"
end

# Many Pathname operations use getwd when they shouldn't, and then throw
# odd exceptions. Reduce our support burden by showing a user-friendly error.
Dir.getwd rescue abort "The current working directory doesn't exist, cannot proceed."

def require?(path)
  require path
rescue LoadError => e
  # HACK: ( because we should raise on syntax errors but
  # not if the file doesn't exist. TODO make robust!
  raise unless e.to_s.include? path
end

begin
  trap("INT", std_trap) # restore default CTRL-C handler

  empty_argv = ARGV.empty?
  help_regex = /(-h$|--help$|--usage$|-\?$|^help$)/
  help_flag = false
  internal_cmd = true
  cmd = nil

  ARGV.dup.each_with_index do |arg, i|
    if help_flag && cmd
      break
    elsif arg =~ help_regex
      help_flag = true
    elsif !cmd
      cmd = ARGV.delete_at(i)
    end
  end

  cmd = HOMEBREW_INTERNAL_COMMAND_ALIASES.fetch(cmd, cmd)

  sudo_check = %w[ install link pin unpin upgrade ]

  if sudo_check.include? cmd
    if Process.uid.zero? and not File.stat(HOMEBREW_BREW_FILE).uid.zero?
      raise <<-EOS.undent
        Cowardly refusing to `sudo brew #{cmd}`
        You can use brew with sudo, but only if the brew executable is owned by root.
        However, this is both not recommended and completely unsupported so do so at
        your own risk.
        EOS
    end
  end

  # Add contributed commands to PATH before checking.
  Dir["#{HOMEBREW_LIBRARY}/Taps/*/*/cmd"].each do |tap_cmd_dir|
    ENV["PATH"] += "#{File::PATH_SEPARATOR}#{tap_cmd_dir}"
  end

  # Add SCM wrappers.
  ENV["PATH"] += "#{File::PATH_SEPARATOR}#{HOMEBREW_LIBRARY}/ENV/scm"

  if cmd
    internal_cmd = require? HOMEBREW_LIBRARY_PATH.join("cmd", cmd)

    if !internal_cmd && ARGV.homebrew_developer?
      internal_cmd = require? HOMEBREW_LIBRARY_PATH.join("dev-cmd", cmd)
    end
  end

  # Usage instructions should be displayed if and only if one of:
  # - a help flag is passed AND an internal command is matched
  # - a help flag is passed AND there is no command specified
  # - no arguments are passed
  #
  # It should never affect external commands so they can handle usage
  # arguments themselves.

  if empty_argv
    $stderr.puts ARGV.usage
    exit 1
  elsif help_flag
    if cmd.nil?
      puts ARGV.usage
      exit 0
    else
      # Handle both internal ruby and shell commands
      require "cmd/help"
      help_text = Homebrew.help_for_command(cmd)
      if help_text.nil?
        # External command, let it handle help by itself
      elsif help_text.empty?
        puts "No help available for #{cmd}"
        exit 1
      else
        puts help_text
        exit 0
      end
    end
  end

  if internal_cmd
    Homebrew.send cmd.to_s.gsub("-", "_").downcase
  elsif which "brew-#{cmd}"
    %w[CACHE CELLAR LIBRARY_PATH PREFIX REPOSITORY].each do |e|
      ENV["HOMEBREW_#{e}"] = Object.const_get("HOMEBREW_#{e}").to_s
    end
    exec "brew-#{cmd}", *ARGV
  elsif (path = which("brew-#{cmd}.rb")) && require?(path)
    exit Homebrew.failed? ? 1 : 0
  else
    onoe "Unknown command: #{cmd}"
    exit 1
  end

rescue FormulaUnspecifiedError
  abort "This command requires a formula argument"
rescue KegUnspecifiedError
  abort "This command requires a keg argument"
rescue UsageError
  onoe "Invalid usage"
  abort ARGV.usage
rescue SystemExit
  puts "Kernel.exit" if ARGV.verbose?
  raise
rescue Interrupt => e
  puts # seemingly a newline is typical
  exit 130
rescue BuildError => e
  e.dump
  exit 1
rescue RuntimeError, SystemCallError => e
  raise if e.message.empty?
  onoe e
  puts e.backtrace if ARGV.debug?
  exit 1
rescue Exception => e
  onoe e
  if internal_cmd
    puts "#{Tty.white}Please report this bug:"
    puts "    #{Tty.em}#{OS::ISSUES_URL}#{Tty.reset}"
  end
  puts e.backtrace
  exit 1
else
  exit 1 if Homebrew.failed?
end
