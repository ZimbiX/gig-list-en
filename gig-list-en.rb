#!/usr/bin/env ruby

# Run with: bundle exec rescue gig-list-en.rb

require 'http'
require 'awesome_print'

def debug(*args)
  ap *args
end

def join_url_params(params)
  params.map { |*a| a.join('=') }.join('&')
end

class GetMusic
  def initialize(my_id:)
    @my_id = my_id
  end

  def call
    get_all_music.tap do
      http.close
    end
  end

  private

  attr_reader :my_id

  def get_all_music
    music = []
    cursor = ''
    while cursor do
      result = get_paginated_music(cursor: cursor)
      music += result.fetch('data')
      cursor = result.fetch('paging').then { |paging| paging['next'] && paging.fetch('cursors').fetch('after') }
    end
    music
  end

  def get_paginated_music(cursor:)
    full_url = "/v4.0/#{my_id}/music?" + join_url_params(
      access_token: access_token,
      fields: 'name',
      limit: 100,
      after: cursor,
    )
    debug full_url
    response = http.get(full_url)
    JSON.parse(response.to_s)
      .tap(&method(:ap))
  end

  def access_token
    # Get token from https://developers.facebook.com/tools/explorer/ with permission for 'user_likes'
    @access_token ||= ENV['FACEBOOK_TOKEN']
  end

  def http
    @http ||= HTTP.persistent('https://graph.facebook.com')
  end
end

class GetPageEvents
  def initialize(page_id:)
    @page_id = page_id
  end

  def call
    get_all_events.tap do
      http.close
    end
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
  end

  def get_paginated_first
    full_url = "/#{page_id}/events/"
    debug full_url
    html = http
      .get(full_url)
      .to_s
    events = html
      .scan(%r{/events/[0-9]+})
      .map { |event| event.split('/').last }
    cursor = extract_cursor(html)
    [events, cursor]
      .tap(&method(:debug))
  end

  def get_paginated_next(cursor:)
    params = {
      page_id: page_id,
      query_type: 'upcoming_exclude_recurring',
      see_more_id: 'u_0_2j',
      serialized_cursor: cursor,
    }
    full_url = '/pages/events/more/?' + join_url_params(params)
    debug full_url
    response = HTTP
      .headers('X-Response-Format' => 'JSONStream')
      .get(full_url)
    js = response.to_s

    events = js
      .scan(%r{href=\\"\\/events\\/[0-9]+})
      .map { |event| event.split('/').last }
    cursor = extract_cursor(js)
    [events, cursor]
      .tap(&method(:debug))
  end

  def extract_cursor(str)
    str
      .scan(/serialized_cursor=[A-Za-z0-9_-]+/)
      .first
      &.sub('serialized_cursor=', '')
  end

  def http
    @http ||= HTTP.persistent('https://m.facebook.com')
  end
end

puts 'Music:'
ap GetMusic.new(my_id: 1597675905).call

puts 'Events for ADTR:'
ap GetPageEvents.new(page_id: 19814903445).call.tap { puts '-' * 100 }
