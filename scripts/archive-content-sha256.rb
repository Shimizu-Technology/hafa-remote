#!/usr/bin/env ruby
require "digest"
require "find"
require "pathname"

# Content, relative paths, file kinds/modes and link targets; timestamps/absolute locations are not payload.
module ArchiveContentDigest
  def self.sha256(path)
    root = File.realpath(path)
    raise ArgumentError, "Archive content digest requires a directory." unless File.directory?(root)
    digest = Digest::SHA256.new
    entries = []
    Find.find(root) { |entry| entries << entry }
    entries.sort_by { |entry| Pathname.new(entry).relative_path_from(Pathname.new(root)).to_s.b }.each do |entry|
      relative = Pathname.new(entry).relative_path_from(Pathname.new(root)).to_s.b
      stat = File.lstat(entry)
      mode = stat.mode & 0o7777
      if stat.symlink?
        target = File.readlink(entry).b
        resolved = File.realpath(entry)
        unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
          raise ArgumentError, "Archive content must not depend on an external symlink target."
        end
        digest.update("L\0#{mode}\0#{relative.bytesize}\0".b).update(relative).update("\0#{target.bytesize}\0".b).update(target)
      elsif stat.directory?
        digest.update("D\0#{mode}\0#{relative.bytesize}\0".b).update(relative)
      elsif stat.file?
        digest.update("F\0#{mode}\0#{relative.bytesize}\0".b).update(relative).update("\0#{stat.size}\0".b)
        File.open(entry, "rb") do |file|
          while (chunk = file.read(65_536))
            digest.update(chunk)
          end
        end
      else
        raise ArgumentError, "Archive content contains an unsupported file type."
      end
    end
    digest.hexdigest
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    abort "Pass the actual validated archive directory." unless ARGV.length == 1
    puts ArchiveContentDigest.sha256(ARGV.first)
  rescue ArgumentError, SystemCallError
    abort "Archive content digest failed; directory, contents or link targets are invalid."
  end
end
