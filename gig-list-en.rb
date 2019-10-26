#!/usr/bin/env ruby

# Run with: bundle exec rescue gig-list-en.rb

require 'http'
require 'awesome_print'
require 'facets/hash/symbolize_keys'
require 'plissken'
require 'yaml'

require_relative 'ruby-progressbar-twoline/ruby-progressbar-twoline.rb'

class ProgressBarLogDelegator < SimpleDelegator
  def puts(*m)
    log(*m)
  end
end

def make_progess_bar(total:)
  progressbar = ProgressBar.create(
    format: "%t %b%i\n%a %E  Processed: %c of %C, %P%",
    remainder_mark: '-',
    total: total,
  )
  logger = ProgressBarLogDelegator.new(progressbar)
  [progressbar, logger]
end

STDOUT.sync = true

def debug(*args)
  ap *args
end

def join_url_params(params)
  params.map { |*a| a.join('=') }.join('&')
end

class GetBands
  def initialize(my_id:)
    @my_id = my_id
  end

  def call
    get_all_bands
  end

  private

  attr_reader :my_id

  def get_all_bands
    bands = []
    cursor = ''
    while cursor do
      result = get_paginated_bands(cursor: cursor)
      bands += result.fetch(:data)
      cursor = result.fetch(:paging).then { |paging| paging[:next] && paging.fetch(:cursors).fetch(:after) }
    end
    bands
      .map(&:symbolize_keys)
      .map { |band| band.merge(id: band[:id].to_i) }
  end

  def get_paginated_bands(cursor:)
    full_url = "/v4.0/#{my_id}/music?" + join_url_params(
      access_token: access_token,
      fields: 'name',
      limit: 100,
      after: cursor,
    )
    debug 'Fetching: ' + full_url
    response = http.get(full_url)
    JSON.parse(response.to_s, symbolize_names: true)
      # .tap(&method(:debug))
  end

  def access_token
    # Get token from https://developers.facebook.com/tools/explorer/ with permission for 'user_likes'
    @access_token ||= ENV.fetch('FACEBOOK_TOKEN')
  end

  def http
    @@http ||= HTTP.persistent('https://graph.facebook.com')
  end
end

class GetPageEventIds
  def initialize(page_id:, logger: STDOUT)
    @page_id = page_id
    @logger = logger
  end

  def call
    get_all_events
  end

  private

  attr_reader :page_id, :logger

  def get_all_events
    events, cursor = get_paginated_first
    while cursor do
      next_events, cursor = get_paginated_next(cursor: cursor)
      events += next_events
    end
    events
      .map(&:to_i)
  end

  def get_paginated_first
    full_url = "/#{page_id}/events/"
    logger.puts ('Fetching: ' + full_url).ai
    html = http
      .get(full_url)
      .to_s
    events = html
      .scan(%r{/events/[0-9]+})
      .map { |event| event.split('/').last }
    cursor = extract_cursor(html)
    [events, cursor]
      # .tap(&method(:debug))
  end

  def get_paginated_next(cursor:)
    params = {
      page_id: page_id,
      query_type: 'upcoming_exclude_recurring',
      see_more_id: 'u_0_2j',
      serialized_cursor: cursor,
    }
    full_url = '/pages/events/more/?' + join_url_params(params)
    logger.puts ('Fetching: ' + full_url).ai
    response = http
      .headers('X-Response-Format' => 'JSONStream')
      .get(full_url)
    js = response.to_s

    events = js
      .scan(%r{href=\\"\\/events\\/[0-9]+})
      .map { |event| event.split('/').last }
    cursor = extract_cursor(js)
    [events, cursor]
      # .tap(&method(:debug))
  end

  def extract_cursor(str)
    str
      .scan(/serialized_cursor=[A-Za-z0-9_-]+/)
      .first
      &.sub('serialized_cursor=', '')
  end

  def http
    @@http ||= HTTP.persistent('https://m.facebook.com')
  end
end

def cached(name:, refresh:)
  FileUtils.mkdir_p('cache')
  filename = "cache/#{name}.yaml"
  if File.exists?(filename) && !refresh
    YAML.load(File.read(filename))
  else
    yield.tap do |data|
      File.write(filename, data.to_yaml)
    end
  end
end

class GetEventDetails
  def initialize(event_id:, logger:)
    @event_id = event_id
    @logger = logger
  end

  def call
    get_event_details
      .tap { |x| logger.puts x.ai }
  end

  private

  attr_reader :event_id, :logger

  def get_event_details
    response = http
      .headers(
        'authority' => 'm.facebook.com',
        'upgrade-insecure-requests' => '1',
        'user-agent' => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/77.0.3865.120 Safari/537.36',
        'sec-fetch-mode' => 'navigate',
        'sec-fetch-user' => '?1',
        'accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3',
        'sec-fetch-site' => 'none',
        'accept-language' => 'en-US,en;q=0.9,en-AU;q=0.8',
        'cookie' => ENV.fetch('FACEBOOK_COOKIES'),
      )
      .get("/events/#{event_id}/")
    html = response.to_s
    json = html
      .scan(%r{<script[> ].+?</script>})
      .find { |s| s.include?('"address":{"') }
      &.gsub(%r{</?script[^>]*>}, '')
    return unless json
    JSON.parse(json, symbolize_names: true)
      .to_snake_keys
  end

  def http
    @@http ||= HTTP.persistent('https://m.facebook.com')
  end
end

puts 'Collecting band IDs from profile likes API...'
bands = cached(name: 'bands', refresh: ARGV.include?('--refresh-band-list')) do
  GetBands.new(my_id: 1597675905).call
end

puts 'Collecting event IDs by scraping band pages...'

progressbar, logger = make_progess_bar(total: bands.count)

output = bands.map do |band|
  band_id = band.fetch(:id)

  event_ids = cached(name: "event-ids-for-band-#{band_id}", refresh: ARGV.include?('--refresh-event-list')) do
    GetPageEventIds.new(page_id: band_id, logger: logger).call
  end

  progressbar.increment

  {
    name: band.fetch(:name),
    id: band_id,
    events: event_ids.map do |event_id|
      {
        id: event_id,
      }
    end
  }
end
progressbar.stop
ap output

puts 'Collecting event details by scraping event pages...'

events_count = output.sum { |band| band.fetch(:events).count }
progressbar, logger = make_progess_bar(total: events_count)

output_with_event_details = output.map do |band|
  band.merge(
    events: band[:events].map do |event|
      event_id = event.fetch(:id)
      event_details = cached(name: "event-details-for-event-#{event_id}", refresh: ARGV.include?('--refresh-event-details')) do
        GetEventDetails.new(event_id: event_id, logger: logger).call
      end

      progressbar.increment

      event.merge(
        details: event_details
      )
    end
  )
end
progressbar.stop
ap output_with_event_details
