require 'rest-client'
require 'multi_json'
require 'logger'

require 'es-reindex/railtie' if defined?(Rails)

class ESReindex

  DEFAULT_URL = 'http://127.0.0.1:9200'

  attr_accessor :src, :dst, :options, :surl, :durl, :sidx, :didx, :start_time, :done

  def self.copy!(src, dst, options)
    self.new(src, dst, options).tap do |reindexer|
      reindexer.setup_index_urls
      reindexer.setup_json_options
      reindexer.go!
    end
  end

  def initialize(src, dst, options = {})
    ESReindex.logger ||= Logger.new(STDERR)

    @src     = src || ''
    @dst     = dst || ''
    @options = {
      from_cli: false, # Coming from CLI?
      remove: false, # remove the index in the new location first
      update: false, # update existing documents (default: only create non-existing)
      frame:  1000   # specify frame size to be obtained with one fetch during scrolling
    }.merge! options

    @done = 0
  end

  def setup_index_urls
    @surl, @durl, @sidx, @didx = '', '', '', ''
    [[src, surl, sidx], [dst, durl, didx]].each do |param, url, idx|
      if param =~ %r{^(.*)/(.*?)$}
        url.replace $1
        idx.replace $2
      else
        url.replace DEFAULT_URL
        idx.replace param
      end
    end
  end

  def go!
    log "Copying '#{surl}/#{sidx}' to '#{durl}/#{didx}'#{remove? ? ' with rewriting destination mapping!' : update? ? ' with updating existing documents!' : '.'}"
    confirm if from_cli?

    success = copy_mappings && copy_docs && check_docs
    if from_cli?
      exit (success ? 0 : 1)
    else
      success
    end
  end

  def confirm
    printf "Confirm or hit Ctrl-c to abort...\n"
    $stdin.readline
  end

  def copy_mappings
    # remove old index in case of remove=true
    retried_request(:delete, "#{durl}/#{didx}") if remove? && retried_request(:get, "#{durl}/#{didx}/_status")

    # (re)create destination index
    unless retried_request :get, "#{durl}/#{didx}/_status"
      # obtain the original index settings first
      unless settings = retried_request(:get, "#{surl}/#{sidx}/_settings")
        log "Failed to obtain original index '#{surl}/#{sidx}' settings!"
        return false
      end
      settings = MultiJson.load settings
      sidx = settings.keys[0]
      settings[sidx].delete 'index.version.created'
      log "Creating '#{durl}/#{didx}' index with settings from '%#{surl}/%#{sidx}'..."
      unless retried_request :post, "#{durl}/#{didx}", MultiJson.dump(settings[sidx])
        log "Creating index #{durl}/#{didx} failed!", :error
        return false
      else
        puts 'OK.'
      end
      unless mappings = retried_request(:get, "#{surl}/#{sidx}/_mapping")
        log "Failed to obtain original index '#{surl}/#{sidx}' mappings!", :error
        return false
      end
      mappings = MultiJson.load mappings
      mappings = mappings[sidx]
      mappings = mappings['mappings'] if mappings.is_a?(Hash) && mappings.has_key?('mappings')
      mappings.each_pair do |type, mapping|
        ESReindex.logger.info "Copying mapping '#{durl}/#{didx}/#{type}'..."
        unless retried_request(:put, "#{durl}/#{didx}/#{type}/_mapping", MultiJson.dump(type => mapping))
          ESReindex.logger.error "Copying mapping '#{durl}/#{didx}/#{type}' failed!"
          return false
        else
          ESReindex.logger.info "Copying mapping '#{durl}/#{didx}/#{type}' OK."
        end
      end
    end

    true
  end

  def copy_docs
    log "Copying '#{surl}/#{sidx}' to '#{durl}/#{didx}'..."
    @start_time = Time.now
    shards = retried_request :get, "#{surl}/#{sidx}/_count?q=*"
    shards = MultiJson.load(shards)['_shards']['total'].to_i
    scan = retried_request :get, "#{surl}/#{sidx}/_search?search_type=scan&scroll=10m&size=#{frame / shards}"
    scan = MultiJson.load scan
    scroll_id = scan['_scroll_id']
    total = scan['hits']['total']
    log "Copy progress: %u/%u (%.1f%%) done.\r" % [done, total, 0]

    bulk_op = update? ? 'index' : 'create'

    while true do
      data = retried_request :get, "#{surl}/_search/scroll?scroll=10m&scroll_id=#{scroll_id}"
      data = MultiJson.load data
      break if data['hits']['hits'].empty?
      scroll_id = data['_scroll_id']
      bulk = ''
      data['hits']['hits'].each do |doc|
        ### === implement possible modifications to the document
        ### === end modifications to the document
        base = {'_index' => didx, '_id' => doc['_id'], '_type' => doc['_type']}
        ['_timestamp', '_ttl'].each{|doc_arg|
          base[doc_arg] = doc[doc_arg] if doc.key? doc_arg
        }
        bulk << MultiJson.dump(bulk_op => base) + "\n"
        bulk << MultiJson.dump(doc['_source'])  + "\n"
        @done = done + 1
      end
      unless bulk.empty?
        bulk << "\n" # empty line in the end required
        retried_request :post, "#{durl}/_bulk", bulk
      end

      eta = total * (Time.now - start_time) / done
      ESReindex.logger.info "Copy progress: %u/%u (%.1f%%) done in %s, E.T.A. : %s.\r" %
                  [done, total, 100.0 * done / total, tm_len, start_time + eta]
    end

    log "Copy progress: %u/%u done in %s.\n" % [done, total, tm_len]
    
    true    
  end

  def check_docs
    log 'Checking document count... '
    scount, dcount = 1, 0
    begin
      Timeout::timeout(60) do
        while true
          scount = retried_request :get, "#{surl}/#{sidx}/_count?q=*"
          dcount = retried_request :get, "#{durl}/#{didx}/_count?q=*"
          scount = MultiJson.load(scount)['count'].to_i
          dcount = MultiJson.load(dcount)['count'].to_i
          break if scount == dcount
          sleep 1
        end
      end
    rescue Timeout::Error
    end
    log "Document count: #{scount} == #{dcount} (#{scount == dcount ? 'equal' : 'NOT EQUAL'})"

    scount == dcount
  end

  class << self
    attr_accessor :logger
  end

  def setup_json_options
    if MultiJson.respond_to? :load_options=
      MultiJson.load_options = {mode: :compat}
      MultiJson.dump_options = {mode: :compat}
    else
      MultiJson.default_options = {mode: :compat}
    end
  end

private

  def log(msg, level = :info)
    ESReindex.logger.send level, msg
  end

  def remove?
    @options[:remove]
  end

  def update?
    @options[:update]
  end

  def frame
    @options[:frame]
  end

  def from_cli?
    @options[:from_cli]
  end

  def tm_len
    l = Time.now - @start_time
    t = []
    t.push l/86400; l %= 86400
    t.push l/3600;  l %= 3600
    t.push l/60;    l %= 60
    t.push l
    out = sprintf '%u', t.shift
    out = out == '0' ? '' : out + ' days, '
    out << sprintf('%u:%02u:%02u', *t)
    out
  end

  def retried_request(method, url, data=nil)
    while true
      begin
        return data ?
          RestClient.send(method, url, data) :
          RestClient.send(method, url)
      rescue RestClient::ResourceNotFound # no point to retry
        return nil
      rescue RestClient::BadRequest => e # Something's wrong!
        log "\n#{method.to_s.upcase} #{url} :-> ERROR: #{e.class} - #{e.message}", :warn
        log e.response, :warn
        return nil
      rescue => e
        log "\nRetrying #{method.to_s.upcase} ERROR: #{e.class} - #{e.message}", :warn
        log e.response, :warn
      end
    end
  end
end
