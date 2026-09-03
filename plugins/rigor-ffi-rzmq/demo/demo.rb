# frozen_string_literal: true

require "ffi-rzmq"

ctx = ZMQ::Context.new
sock = ctx.socket(ZMQ::REQ)
sock.connect("tcp://127.0.0.1:5555")
sock.close
ctx.terminate
