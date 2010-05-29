require 'rubygems'
require 'eventmachine'
require 'uuid'
require 'yajl'
require 'cgi'

class Room < EM::Channel
  attr_accessor :log
  
  def initialize
    @log = []
    super
  end
  def say(nick, type, text = nil)
    m = {:nick => nick, :type => type}
    m[:text] = text if text
    @log << m
    str = Yajl::Encoder.encode({:messages => [m]})
    push(str)
  end
end

$users = {}
$room = Room.new
$index_html = File.read('index.html')
$client_js = File.read('client.js')
$style_css = File.read('style.css')

class LongPollHttpServer < EM::Connection

  def unbind
    $room.unsubscribe(@subscription)
  end

  def receive_data(data)
    lines = data.split(/[\r\n]+/)
    method, request, version = lines.shift.split(' ', 3)
    if request.nil?
      puts "#{Time.now} Warning: strange request #{[method, request, version].inspect}"
      close_connection
      return
    else
      path, query = request.split('?', 2)
      query = CGI.parse(query) if not query.nil?
      cookies = {}
      lines.each do |line|
        if line[0..6].downcase == 'cookie:'
          cookies = CGI::Cookie.parse(line.split(':', 2).last.strip)
        end
      end
    end

    require "pp"
    pp "#{path} with #{query}"
   
    case path

    when '/'
      respond $index_html, 200, 'text/html'

    when '/client.js'
      respond $client_js, 200, 'application/javascript'

    when '/style.css'
      respond $style_css, 200, 'text/css'

    when '/join'
      nick = query['nick'].first
      id = UUID.new.generate
      $users[id] = {:nick => nick}
      $room.say(nick, "join")
      str = Yajl::Encoder.encode({:id => id, :nick => nick})
      respond str, 200, 'application/json'

    when '/send'
      id = query['id'].first
      text = query['text'].first
      nick = $users[id][:nick]
      $room.say nick, 'msg', text.gsub('"', '\"')
      str = Yajl::Encoder.encode({})
      respond str, 200, 'application/json'

    when '/recv'
      @subscription = $room.subscribe do |msg|
        respond msg, 200, "application/json"
      end

    # when '/status'
    #   respond "connections: #{EM.connection_count}\n" +
    #     "total: #{ObjectSpace.count_objects[:TOTAL]}\n" +
    #     "free: #{ObjectSpace.count_objects[:FREE]}\n"

    when '/who'
      str = Yajl::Encoder.encode({:nicks => $users.values.map{|x| x[:nick]}})
      respond str, 200, 'application/json'

    when '/part'
      id = query['id'].first
      if $users[id]
        nick = $users[id][:nick]
        $room.say nick, 'part'
        $users.delete id
      end
      str = Yajl::Encoder.encode({})
      respond str, 200, 'application/json'

    else
      respond "not found", 404
    end
  end

  RESPONSE = [
    "HTTP/1.1 %d PLOP",
    "Content-length: %d",
    "Content-type: %s",
    "Connection: close",
    "",
    "%s"].join("\r\n")

  def respond(body, status = 200, content_type = 'text/comet')
    send_data RESPONSE % [status, body.length, content_type, body]
    close_connection_after_writing
  end

end

loop do
  begin
    GC.start
    EM.epoll if EM.epoll?
    EM.run do
      puts "#{Time.now} Starting server on port #{ARGV.first || 8000}"
      EM.start_server '0.0.0.0', ARGV.first || 8000, LongPollHttpServer
    end
  rescue Interrupt
    puts "#{Time.now} Shuting down..."
    exit
  rescue
    puts "#{Time.now} Error: " + $!.message
    puts "\t" + $!.backtrace.join("\n\t")
  end
end
