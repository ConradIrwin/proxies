#!/usr/bin/env ruby

require 'socket'
s = UDPSocket.new
s.bind(nil, ARGV[0] || 8125)
loop do
  text, _ = s.recvfrom(1000)
  p text
end
