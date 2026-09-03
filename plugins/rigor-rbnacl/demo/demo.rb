# frozen_string_literal: true

require "rbnacl"

key = "0" * 32
box = RbNaCl::SecretBox.new(key)
nonce = "1" * 24
message = "hello world"
ciphertext = box.encrypt(nonce, message)
puts box.decrypt(nonce, ciphertext)
