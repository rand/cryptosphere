require 'tempfile'
require 'fileutils'

module Cryptosphere
  class Blob
    # Prefix added to the beginning of every Cryptosphere node
    PREFIX = "blob::"

    attr_reader :id, :key, :path

    class << self
      attr_reader :path

      # Configure the Cryptosphere Node store
      def setup(options = {})
        unless options[:root]
          raise ArgumentError, "no :root path given"
        end

        unless File.directory? options[:root]
          raise ArgumentError, "no such directory: #{options[:root]}"
        end

        @path = File.expand_path("nodes", options[:root])
        FileUtils.mkdir @path unless File.directory? @path

        nil
      end

      # Create a node from a given object
      def [](obj)
        builder = Builder.new
        builder << obj
        builder.finish
      end
    end

    def initialize(id, key)
      @id, @key = id, key
      @path = File.join(self.class.path, @id)
    end

    def decrypt
      raise "can't decrypt node without key" unless @key

      cipher = Cryptosphere.block_cipher
      cipher.decrypt
      cipher.key = @key[0...32]
      cipher.iv  = @key[32...64]

      output = ''

      File.open(@path, 'r') do |file|
        while data = file.read(4096)
          output << cipher.update(data)
        end
      end

      output << cipher.final
    end

    # Encrypt a node and insert it into the local store
    class Builder
      def initialize
        @hash_cipher = Cryptosphere.hash_cipher
        @hash_cipher << PREFIX

        @file = Tempfile.new 'cryptosphere'
      end

      def write(data)
        @hash_cipher << data
        @file << data
      end
      alias_method :<<, :write

      def derive_key(hash)
        salt, secret = hash[0...16], hash[16...32]
        data = Cryptosphere.kdf(secret, salt)
        key, iv = data[0...32], data[32...64]
        return key, iv
      end

      def finish
        key, iv = derive_key @hash_cipher.digest

        block_cipher = Cryptosphere.block_cipher
        block_cipher.encrypt
        block_cipher.key, block_cipher.iv = key, iv

        @file.rewind
        output = Tempfile.new 'cryptosphere'

        begin
          hash_cipher = Cryptosphere.hash_cipher
          while plaintext = @file.read(4096)
            ciphertext = block_cipher.update(plaintext)
            output << ciphertext
            hash_cipher << ciphertext
          end

          ciphertext = block_cipher.final
          output << ciphertext
          hash_cipher << ciphertext
          output.close

          node_id = hash_cipher.hexdigest
          FileUtils.mv output.path, File.join(Blob.path, node_id)

          Blob.new(node_id, key + iv)
        rescue Exception
          output.close rescue nil
          output.unlink rescue nil

          raise
        end
      ensure
        @file.close rescue nil
        @file.unlink rescue nil
      end
    end
  end
end
