#! /usr/bin/env ruby
# typed: true
# frozen_string_literal: true

require 'dotenv/load'
require 'sorbet-runtime'
require 'debug'

require 'fileutils'
require 'csv'
require 'open-uri'
require 'nokogiri'
require 'discogs'

require 'logger'

extend T::Sig

PROJECT_NAME = ENV.fetch('PROJECT_NAME', 'discogs-import')
DISCOGS_USERNAME = ENV.fetch('DISCOGS_USERNAME', 'unspecified-user')
DISCOGS_USER_TOKEN = ENV.fetch('DISCOGS_USER_TOKEN', 'unspecified-token')
SUPPRESS_WARNINGS = ENV.fetch('SUPPRESS_WARNINGS', 'false')
CACHE_DIR = ENV.fetch('CACHE_DIR', './cache/')
VERBOSE_CACHE = ENV.fetch('VERBOSE_CACHE', 'false')
CORRECTED_ALBUM_SEARCH_INDEXES_FILE = ENV.fetch('CORRECTED_ALBUM_SEARCH_INDEXES_FILE', 'corrected_album_search_indexes.json')

if SUPPRESS_WARNINGS == 'true'
  # Hashie::Mash is a dependency of the 6yo discogs-wrapper gem and is very noisy
  logger = Logger.new(STDOUT)
  logger.level = Logger::ERROR
  Object.const_get(:Hashie).logger = logger
  $stderr = File.open(File::NULL, 'w')
end

METHODS_TO_CACHE = %i[search get_master_release]

class CachedDiscogs
  extend T::Sig

  sig { params(verbose: T::Boolean).void }
  def initialize(verbose: false)
    @wrapper = Object.const_get('Discogs::Wrapper').new('discogs-import', user_token: DISCOGS_USER_TOKEN)
    @cache_dir = CACHE_DIR
    Dir.mkdir(@cache_dir) unless Dir.exist?(@cache_dir)
    @methods_to_cache = METHODS_TO_CACHE
    @verbose = VERBOSE_CACHE == 'true'
  end


  sig { params(method: Symbol, args: T.untyped).returns(T.untyped) }
  def method_missing(method, *args)
    # I can't believe I'm using method_missing, but this kinda makes the caching clean.
    # And it's not like Sorbet can help with the gem return values anyway.
    if @methods_to_cache.include?(method)
      T.unsafe(self).send(:cached_call, method, *args)
    else
      T.unsafe(self).send(:call, method, *args)
    end
  end

  private

  sig { params(method: Symbol, args: T.untyped).returns(T.untyped) }
  def cached_call(method, *args)
    raise 'Method not cacheable' unless @methods_to_cache.include?(method)

    normalized_args = args.map { |arg| arg.is_a?(Hash) ? arg.sort : arg }
    cache_file = "#{@cache_dir}#{Digest::SHA256.hexdigest(JSON.dump([method, normalized_args]))}.json"
    if File.exist?(cache_file)
      puts 'CACHE HIT' if @verbose
    else
      puts 'CACHE MISS' if @verbose
      response = @wrapper.send(method, *args)
      sleep(1) # Don't slam the Discogs API - they have a rate limit
      result = response.to_hash.to_json
      File.write(cache_file, result)
    end

    JSON.parse(File.read(cache_file)) 
  end

  sig { params(method: Symbol, args: T.untyped).returns(T.untyped) }
  def call(method, *args)
    response = @wrapper.send(method, *args)
    sleep(1) # Don't slam the Discogs API - they have a rate limit
    result = response.to_hash.to_json
    JSON.parse(result)
  end
end

wrapper = T.unsafe(CachedDiscogs.new)

sig { params(images_array: T::Array[T.untyped]).void }
def print_image(images_array)
  image = images_array.find { |image| image['type'] == 'primary' } || 
    images_array.find { |image| image['type'] == 'secondary' } || 
    images_array.first
  image_uri = image&.dig('uri') || ''
  # really trying not to feed random internet-provded strings into my command line
  case (URI.parse(image_uri))
  when nil
    puts 'NO IMAGE FOUND'
  when URI::HTTPS
    system("~/.iterm2/imgcat --preserve-aspect-ratio -W 12 --url '#{image_uri}'")
  else
    puts "Invalid image URI: #{image_uri}"
  end
end

sig { returns(T::Array[[String, String]]) }
def get_artist_albums

  # ATTENTION: This whole method will need to be tweaked to return the artist-album tuples from whatever source.

  inside_collection = T.let(false, T::Boolean)
  inside_table = T.let(false, T::Boolean)
  tuples = []
  File.foreach('/Users/anthony.ho/Documents/a bugs life/3 Resources/records/Records.md') do |line|
    if line.strip == "## Collection"
      inside_collection = true
      next
    end

    if inside_collection && line.start_with?("##")
      inside_collection = false
      next
    end

    # skip header row
    if !inside_table && line.include?("Album")
      inside_table = true
      next
    end

    # skip separator row
    next if line.include?("-------------")

    if inside_table && line.start_with?("|")
      row = CSV.parse_line(line, col_sep: '|')&.compact&.map(&:strip)
      raise "Invalid row: #{line}" if row.nil? || row.empty?
      album, artist, *_rest = row

      tuples << [artist, album]
    end
  end

  tuples
end

sig { params(index: T.nilable(Integer), artist: String, album: String).void }
def set_album_search_index(index:, artist:, album:)
  file_contents = File.read(CORRECTED_ALBUM_SEARCH_INDEXES_FILE)
  album_search_index_hash = JSON.parse(file_contents == '' ? '{}' : file_contents)
  album_search_index_hash["#{artist} - #{album}"] = index
  File.write(CORRECTED_ALBUM_SEARCH_INDEXES_FILE, JSON.pretty_generate(album_search_index_hash.sort.to_h))
end

master_ids = []
missing_albums = []
pagination_params = { page: 1, per_page: 7 }
get_artist_albums.each do |artist, album|
  artist_album_key = "#{artist} - #{album}"
  response = wrapper.search(artist_album_key, type: :master, **pagination_params)
  search_results = response['results']
  if search_results.nil? || search_results.empty?
    puts "404: No results found for #{[artist, album]}"
    missing_albums << [artist, album]
    next 
  end
  
  FileUtils.touch(CORRECTED_ALBUM_SEARCH_INDEXES_FILE)
  indexes_file = File.read(CORRECTED_ALBUM_SEARCH_INDEXES_FILE)
  album_search_index_hash = JSON.parse(indexes_file == '' ? '{}' : indexes_file)
  found_index = T.let(album_search_index_hash.key?(artist_album_key), T::Boolean)
  index = album_search_index_hash[artist_album_key] || 0
  master_id = T.let(search_results[index]['id'], T.nilable(Integer))
  while !found_index
    master_id = search_results[index]['id']
    master = T.let(wrapper.get_master_release(master_id), T.untyped)
    if master.nil? || master.empty?
      puts "500: Discog error - master #{master_id} not found for #{[artist, album]}: \n#{response}"
      next
    end

    puts "\n\n#{artist} - #{album} (#{master_id})"
    print_image(master['images'])

    loop do
      print "Is this the correct album? (Y/n/[m]issing/?): "
      case gets.chomp
      when 'y'
        found_index = true 
        set_album_search_index(index:, artist:, album:)
      when 'n'
        if index == search_results.length - 1
          puts 'Exhausted search results. Resetting index...'
          index = 0
        else
          index += 1
        end
      when 'm'
        puts 'Marking album as missing...'
        found_index = true
        set_album_search_index(index: nil, artist:, album:)
        missing_albums << [artist, album]
      when '?'
        found_index = true
        missing_albums << [artist, album]
      else
        puts 'Invalid response. Please enter "y" for yes, "n" for no, "m" for missing, or "?" for unsure.'
        next
      end
      break
    end
  end

  master_ids << master_id
end

puts 'Missing albums:'
missing_albums.each { |artist, album| puts "#{artist} - #{album}" }

puts "\n\nAbout to add the above albums to your Discogs wantlist. Press enter to continue..."
gets

master_releases_by_main_release_id = master_ids
  .map { |id| wrapper.get_master_release(id) }
  # inefficient .index_by implementation:
  .group_by { |master_release| master_release['main_release'] }
  .transform_values { |master_releases| master_releases.last }

master_releases_by_main_release_id.each do |release_id, master|
  # roll the credits
  print_image(master['images'])
  wrapper.add_release_to_user_wantlist(DISCOGS_USERNAME, release_id, { rating: 0 })
  sleep(2)
end
