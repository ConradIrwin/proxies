#!/usr/bin/env ruby
require 'zlib'
require 'eventmachine'
require 'ipaddr'
require 'base64'
require 'json'
require 'time'

arg = ARGV.shift
if arg == '--json'
  $write_json_files = true
  arg = ARGV.shift
end

$listen_port, $upstream_host, $upstream_port, _ = (arg || "").split(":")

$upstream_proxy = !!($upstream_port && $upstream_port.sub!('p', ''))
$listen_proxy = !!($listen_port && $listen_port.sub!('p', ''))
$upstream_tls = !!($upstream_port && $upstream_port.sub!('s', ''))
$listen_tls = !!($listen_port && $listen_port.sub!('s', ''))

if $listen_port =~ /^[0-9]+$/ and $upstream_port =~ /^[0-9]+$/ and $upstream_host and not _
  puts "Listening: 0.0.0.0:#{$listen_port} => #{$upstream_host}:#{$upstream_port}"
else
  puts <<-DOC
Usage: logging_proxy.rb [--json] [s]<listen-port>:<upstream-hostname>:<upstream-port>[s][p]

Creates a transparent TCP proxy (with support for the imap COMPRESS DEFLATE command)
Client requests are output to STDOUT in red, upstream replies in blue
Optionally also writes structured logs to a JSON files (one file per connection)

You can use TLS on downstream by specifing the port as "s<port>", and upstream with "<port>s".
You can also ask the proxy to add a PROXY protocol header upstream with "<port>p".
  DOC
  exit
end
$stdout.flush

$listen_port = $listen_port.to_i
$upstream_port = $upstream_port.to_i


module LogWriter
  def log(category, data=nil, options={})
    if options[:deflated]
      # Any number between -8 and -15 seems to work: see also https://github.com/igrigorik/em-http-request/pull/103
      @zlib ||= Zlib::Inflate.new(-15)
      deflated = data
      data = @zlib.inflate(data)
    else
      deflated = nil
    end

    case category
    when :connect          then print "\e[42m<connect>\e[0m"
    when :starttls         then print "\e[42m<starttls>\e[0m"
    when :upwards          then print "\e[31m#{data}\e[0m"
    when :downwards        then print "\e[34m#{data}\e[0m"
    when :deflating        then print "\e[42m<deflating>\e[0m"
    when :downstream_close then print "\e[41m<client-bye>\e[0m"
    when :upstream_close   then print "\e[41m<server-bye>\e[0m"
    end

    if json_log
      entry = {:timestamp => (Time.now.to_r * 1_000_000).to_i, :category => category}
      entry['data'] = Base64.encode64(data) if category == :upwards || category == :downwards
      entry['deflated'] = Base64.encode64(deflated) if deflated
      json_log.write(entry.to_json)
      json_log.write("\n")
    end
  end

  def init_json_log
    if $write_json_files
      self.json_log = File.open("logging_proxy_#{(Time.now.to_r * 1_000_000).to_i}.json", 'w')
    end
  end

  def close_json_log
    if json_log
      json_log.close
      self.json_log = nil
    end
  end
end


class ProxyUpstream < EM::Connection
  include LogWriter
  attr_accessor :json_log

  def initialize(downstream)
    @downstream = downstream
    super
  end

  def post_init
    send_proxy_line if $upstream_proxy
    start_tls if $upstream_tls
  rescue => e
    puts e
  end

  def receive_data(data)
    if @downstream.state == :pending_deflate && data =~ /OK/
      @downstream.state = :deflating
      log :downwards, data
      log :deflating
    else
      log :downwards, data, :deflated => (@downstream.state == :deflating)
      $stdout.flush
    end

    $stdout.flush

    @downstream.send_data(data)
  end

  def unbind
    log :upstream_close
    @downstream.close_connection
  end

  def send_proxy_line
    remote_port, remote_ip = Socket.unpack_sockaddr_in(@downstream.get_peername)
    proxy_port, proxy_ip = Socket.unpack_sockaddr_in(@downstream.get_sockname)
    family = IPAddr.new(remote_ip).ipv6? ? 'TCP6' : 'TCP4'
    send_data "PROXY #{family} #{remote_ip} #{proxy_ip} #{remote_port} #{proxy_port}\r\n"
  end
end

module ProxyDownstream
  include LogWriter
  attr_accessor :json_log, :state

  def post_init
    init_json_log
    log :connect
    @upstream = EM::connect $upstream_host, $upstream_port, ProxyUpstream, self
    @upstream.json_log = json_log
    start_tls :private_key_file => "localhost.key", :cert_chain_file => "localhost.crt" if $listen_tls
    @starting = true
  end

  def receive_data(data)
    if @starting
      @starting = false
      data.sub!(/PROXY.*\r\n/, '') if $listen_proxy
    end

    if data =~ /COMPRESS DEFLATE/
      @state = :pending_deflate
    elsif data =~ /STARTTLS/
      @state = :pending_starttls
    end

    log :upwards, data, :deflated => (@state == :deflating)
    $stdout.flush

    @upstream.send_data(data)
  end

  def send_data(data)
    super
    if @state == :pending_starttls
      @upstream.start_tls
      start_tls  :private_key_file => "config/ssl/rapportress.key", :cert_chain_file => "config/ssl/rapportress.crt"
      log :starttls
      @state = :secure
    end
  end

  def unbind
    log :downstream_close
    @upstream.close_connection
    @upstream.json_log = nil
    close_json_log
  end
end

Signal.trap('INT') { EM::stop }
EventMachine.run {
  EventMachine.start_server "0.0.0.0", $listen_port, ProxyDownstream
}

