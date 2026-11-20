# frozen_string_literal: true

module Nightshift
  # Small helpers shared by every module: file IO that never leaves half-written files,
  # UTF-8 safe reads, timestamps.
  module Util
    module_function

    # Read a text file as UTF-8, replacing invalid bytes. Returns "" if the file does not exist.
    def read(path)
      return "" unless File.file?(path)

      File.binread(path).force_encoding(Encoding::UTF_8).scrub
    end

    # Write text as UTF-8 with LF line endings, creating parent folders.
    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, text.to_s.encode(Encoding::UTF_8))
    end

    def append(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "ab") { |f| f.write(text.to_s.encode(Encoding::UTF_8)) }
    end

    # Last +lines+ lines (at most +chars+ characters) of a file; used for gate error output.
    def tail(path, lines = 40, chars = 3000)
      text = read(path).lines.last(lines).join.chomp
      text.length > chars ? text[-chars..] : text
    end

    def read_json(path, default)
      return deep_copy(default) unless File.file?(path)

      JSON.parse(read(path))
    end

    # Atomic on the same volume: a crash or power cut never leaves half a JSON file behind.
    def write_json(path, data)
      tmp = "#{path}.tmp"
      write(tmp, "#{JSON.pretty_generate(data)}\n")
      File.rename(tmp, path)
    end

    def deep_copy(obj) = Marshal.load(Marshal.dump(obj))

    # Merge +over+ into +base+ recursively (hashes merge, everything else replaces).
    def deep_merge(base, over)
      base.merge(over) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : deep_copy(new)
      end
    end

    def now_iso = Time.now.strftime("%Y-%m-%dT%H:%M:%S")

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Forward slashes, no leading "./". Every path comparison in nightshift goes through this.
    def norm(path)
      path = path.to_s.tr("\\", "/")
      path = path.delete_prefix("./") while path.start_with?("./")
      path
    end

    def sha256(path) = Digest::SHA256.file(path).hexdigest
  end
end
