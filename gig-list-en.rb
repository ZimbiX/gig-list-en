#!/usr/bin/env ruby

# Run with: bundle exec rescue gig-list-en.rb

require 'http'
require 'awesome_print'
require 'facets/hash/symbolize_keys'
require 'yaml'

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
      bands += result.fetch('data')
      cursor = result.fetch('paging').then { |paging| paging['next'] && paging.fetch('cursors').fetch('after') }
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
    JSON.parse(response.to_s)
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
  def initialize(page_id:)
    @page_id = page_id
  end

  def call
    get_all_events
  end

  private

  attr_reader :page_id

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
    debug 'Fetching: ' + full_url
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
    debug 'Fetching: ' + full_url
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

puts 'Bands:'
bands = cached(name: 'bands', refresh: ARGV.include?('--refresh-bands')) do
  GetBands.new(my_id: 1597675905).call
end

output = bands.map do |band|
  band_id = band.fetch(:id)

  event_ids = cached(name: "event-ids-for-band-#{band_id}", refresh: ARGV.include?('--refresh-events')) do
    GetPageEventIds.new(page_id: band_id).call
  end

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
ap output
