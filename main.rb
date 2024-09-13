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

DISCOGS_USERNAME = ENV.fetch('DISCOGS_USERNAME', 'unspecified-user')
DISCOGS_USER_TOKEN = ENV.fetch('DISCOGS_USER_TOKEN', 'unspecified-token')
SUPPRESS_WARNINGS = ENV.fetch('SUPPRESS_WARNINGS', 'false')
CACHE_DIR = ENV.fetch('CACHE_DIR', './cache/')
VERBOSE_CACHE = ENV.fetch('VERBOSE_CACHE', 'false')
PROJECT_NAME = ENV.fetch('PROJECT_NAME', 'discogs-import')

if SUPPRESS_WARNINGS == 'true'
  logger = Logger.new(STDOUT)
  logger.level = Logger::ERROR
  Object.const_get(:Hashie).logger = logger

  old_stderr = $stderr
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
      sleep(1)
      result = response.to_hash.to_json
      File.write(cache_file, result)
    end

    JSON.parse(File.read(cache_file)) 
  end

  sig { params(method: Symbol, args: T.untyped).returns(T.untyped) }
  def call(method, *args)
    @wrapper.send(method, *args)
  end
end

wrapper = T.unsafe(CachedDiscogs.new)

sig { params(images_array: T::Array[T.untyped]).void }
def print_image(images_array)
  image = images_array.find { |image| image['type'] == 'primary' } || 
    images_array.find { |image| image['type'] == 'primary' } || 
    images_array.first
  image_uri = URI.parse(image&.dig('uri')) rescue nil
  if image_uri.nil?
    puts 'NO IMAGE FOUND'
  elsif image_uri.is_a?(URI::HTTPS)
    system("~/.iterm2/imgcat --preserve-aspect-ratio -W 12 --url '#{image_uri}'")
  else
    puts "Invalid image URI: #{image_uri}"
  end
end

sig { returns(T::Array[[String, String]]) }
def get_artist_albums
  inside_collection = T.let(false, T::Boolean)
  tuples = []

  File.foreach('/Users/anthony.ho/Documents/a bugs life/3 Resources/records/Records.md') do |line|
    if line.strip == "## Collection"
      inside_collection = true
      next
    end

    # Stop parsing if a new section (heading starting with ## or ###) is encountered
    if inside_collection && line.start_with?("##")
      inside_collection = false
      next
    end

    # Extract the table data once we are inside the "## Collection" section
    if inside_collection && line.start_with?("|")
      # Skip the header and separator rows
      next if line.include?("Album") || line.include?("---")

      # Use CSV to handle the table row and split it into columns
      row = CSV.parse_line(line, col_sep: '|')&.compact&.map(&:strip)
      raise "Invalid row: #{line}" if row.nil? || row.empty?
      album, artist, *_rest = row # Assuming "Album" is the first column after index 0

      # Append the tuple [artist, album] if both exist
      tuples << [artist, album]
    end
  end

  tuples
end

CORRECTED_ALBUM_SEARCH_INDEXES_FILE = 'corrected_album_search_indexes.json'

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
  skip = T.let(album_search_index_hash.key?(artist_album_key), T::Boolean)
  index = album_search_index_hash[artist_album_key] || 0
  master_id = T.let(search_results[index]['id'], T.nilable(Integer))
  while !skip
    master_id = T.let(search_results[index]['id'], T.nilable(Integer))
    master = T.let(wrapper.get_master_release(master_id), T.untyped)
    if master.nil? || master.empty?
      puts "500: Discog error - master #{master_id} not found for #{[artist, album]}: \n#{response}"
      next
    end

    puts "\n\n#{artist} - #{album} (#{master_id})"
    print_image(master['images'])

    loop do
      print "Is this the correct album? (Y/n/[m]issing/?): "
      case (response = gets.chomp)
      when 'y'
        skip = true 
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
        skip = true
        set_album_search_index(index: nil, artist:, album:)
        missing_albums << [artist, album]
      when '?'
        skip = true
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
pp missing_albums

# TODO: add to Discogs Want list


debugger

