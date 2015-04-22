require "redis"
require "httparty"
require "pusher"

require "erb"
require "time"

class Giphy
  include HTTParty
  base_uri 'api.giphy.com'

  def initialize(api_key = ENV['GIPHY_KEY'] || 'dc6zaTOxFJmzC&q')
    @api_key = api_key
  end

  def image(term)
    data = search(term)
    data["data"].first["images"]["original"]["url"]
  end

  def search(term)
    term = "dont" if term.to_s == "0"
    return @last_data if @last_term == term
    @last_term = term
    @last_data = self.class.get("/v1/gifs/search?api_key=#{@api_key}&q=#{term}")
  end
end

CACHE_BUST = {
  "Cache-Control" => "private, max-age=0, no-cache, no-store",
  "Expires" => "Thu, 01 Dec 1983 20:00:00 GMT",
  "Pragma" => "no-cache",
}

module ::Kernel
  def sendfile(file, mime_type, cache)
    lambda do |env|
      [
        200,
        {
          "Content-Length" => File.size(file).to_s,
          "Content-Type" => mime_type,
          "Date" => Time.now.httpdate,
        }.merge(cache ? {} : CACHE_BUST),
        File.open(file),
      ]
    end
  end
end

if ENV["REDISTOGO_URL"]
  uri = URI.parse(ENV["REDISTOGO_URL"])
  redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
else
  redis = Redis.new
end

giphy = Giphy.new

map '/the-button' do
  run ->(env) {
    url = giphy.image(
      redis.get("presses") || 'dont'
    )
    [303, {'Location' => url}.merge(CACHE_BUST), []]
  }
end

map '/dont-press' do
  run ->(env) {
    count = redis.incr("presses")
    url = giphy.image(count)
    p count: count, url: url
    Pusher.trigger('the-button', 'press', {count: count, url: url})
    [303, {'Location' => '/'}.merge(CACHE_BUST), []]
  }
end

map '/count' do
  run ->(env){
    [200, {'Content-Type' => 'text/plain'}, [redis.get('presses').to_s]]
  }
end

map '/reset' do
  run ->(env){
    redis.set('presses', '0')
    [303, {'Location' => '/'}.merge(CACHE_BUST), []]
  }
end

run ->(env) {
  page = ERB.new(File.read('index.html.erb'), nil, '<>-').result(binding)
  [
    200,
    {'Content-Type' => 'text/html', 'Content-Length' => page.bytesize.to_s},
    [page],
  ]
}
