# encoding: UTF-8
require 'open-uri'
require 'money'
require 'json'

# Money gem class
class Money
  # https://github.com/RubyMoney/money#exchange-rate-stores
  module Bank
    # Invalid cache, file not found or cache empty
    class InvalidCache < StandardError; end

    # App id not set error
    class NoAccessKey < StandardError; end

    # CurrencylayerBank base class
    # rubocop:disable Metrics/ClassLength
    class CurrencylayerBank < Money::Bank::VariableExchange
      # CurrencylayerBank url
      CL_URL = 'http://apilayer.net/api/live'.freeze
      # CurrencylayerBank secure url
      CL_SECURE_URL = CL_URL.gsub('http:', 'https:').freeze
      # Default base currency
      CL_SOURCE = 'USD'.freeze

      # Use https to fetch rates from CurrencylayerBank
      # CurrencylayerBank only allows http as connection
      # for the free plan users.
      #
      # @param value [Boolean] true for secure connection
      #
      # @return [Boolean] chosen secure connection
      attr_accessor :secure_connection

      # API must have a valid access_key
      #
      # @param value [String] API access key
      #
      # @return [String] chosen API access key
      attr_accessor :access_key

      # Cache accessor, can be a String or a Proc
      #
      # @param value [String,Pathname,Proc] cache system
      #
      # @return [String,Pathname,Proc] chosen cache system
      attr_accessor :cache

      # Parsed CurrencylayerBank result as Hash
      attr_reader :rates

      # Set the seconds after than the current rates are automatically expired
      # by default, they never expire.
      #
      # @example
      #   ttl_in_seconds = 86400 # will expire the rates in one day
      #
      # @param value [Integer] time to live in seconds
      #
      # @return [Integer] chosen time to live in seconds
      attr_writer :ttl_in_seconds

      # Set the base currency for all rates. By default, USD is used.
      # CurrencylayerBank only allows USD as base currency
      # for the free plan users.
      #
      # @example
      #   source = 'USD'
      #
      # @param value [String] Currency code, ISO 3166-1 alpha-3
      #
      # @return [String] chosen base currency
      def source=(value)
        @source = Money::Currency.find(value.to_s).try(:iso_code) || CL_SOURCE
      end

      # Get the base currency for all rates. By default, USD is used.
      # @return [String] base currency
      def source
        @source ||= CL_SOURCE
      end

      # Get the seconds after than the current rates are automatically expired
      # by default, they never expire.
      # @return [Integer] chosen time to live in seconds
      def ttl_in_seconds
        @ttl_in_seconds ||= 0
      end

      # Update all rates from CurrencylayerBank JSON
      # @return [Array] array of exchange rates
      def update_rates(straight = false)
        exchange_rates(straight).each do |exchange_rate|
          currency = exchange_rate.first[3..-1]
          rate = exchange_rate.last
          next unless Money::Currency.find(currency)
          add_rate(source, currency, rate)
          add_rate(currency, source, 1.0 / rate)
        end
      end

      # Override Money `get_rate` method for caching
      # @param [String] from_currency Currency ISO code. ex. 'USD'
      # @param [String] to_currency Currency ISO code. ex. 'CAD'
      #
      # @return [Numeric] rate.
      def get_rate(from_currency, to_currency, opts = {}) # rubocop:disable all
        expire_rates!
        rate = super
        unless rate
          # Tries to calculate an inverse rate
          inverse_rate = super(to_currency, from_currency, opts)
          if inverse_rate
            rate = 1.0 / inverse_rate
            add_rate(from_currency, to_currency, rate)
          end
        end
        unless rate
          # Tries to calculate a pair rate using base currency rate
          from_base_rate = super(source, from_currency, opts)
          unless from_base_rate
            from_inverse_rate = super(from_currency, source, opts)
            from_base_rate = 1.0 / from_inverse_rate if from_inverse_rate
          end
          to_base_rate = super(source, to_currency, opts)
          unless to_base_rate
            to_inverse_rate = super(to_currency, source, opts)
            to_base_rate = 1.0 / to_inverse_rate if to_inverse_rate
          end
          if to_base_rate && from_base_rate
            rate = to_base_rate / from_base_rate
            add_rate(from_currency, to_currency, rate)
          end
        end
        rate
      end

      # Fetch new rates if cached rates are expired
      # @return [Boolean] true if rates are expired and updated from remote
      def expire_rates!
        if expired?
          update_rates(true)
          true
        else
          false
        end
      end

      # Check if rates are expired
      # @return [Boolean] true if rates are expired
      def expired?
        Time.now > rates_expiration
      end

      # Source url of CurrencylayerBank
      # defined with access_key and secure_connection
      # @return [String] the remote API url
      def source_url
        raise NoAccessKey if access_key.nil? || access_key.empty?
        cl_url = CL_URL
        cl_url = CL_SECURE_URL if secure_connection
        "#{cl_url}?source=#{source}&access_key=#{access_key}"
      end

      # Get rates expiration time based on ttl
      # @return [Time] rates expiration time
      def rates_expiration
        rates_timestamp + ttl_in_seconds
      end

      # Get the timestamp of rates
      # @return [Time] time object or nil
      def rates_timestamp
        raw = raw_rates_careful
        raw.key?('timestamp') ? Time.at(raw['timestamp']) : Time.at(0)
      end

      protected

      # Store the provided text data by calling the proc method provided
      # for the cache, or write to the cache file.
      #
      # @example
      #   store_in_cache("{\"quotes\": {\"USDAED\": 3.67304}}")
      #
      # @param text [String] parsed JSON content
      # @return [String,Integer]
      def store_in_cache(text)
        if cache.is_a?(Proc)
          cache.call(text)
        elsif cache.is_a?(String) || cache.is_a?(Pathname)
          write_to_file(text)
        end
      end

      # Writes content to file cache
      # @param text [String] parsed JSON content
      # @return [String,Integer]
      def write_to_file(text)
        open(cache, 'w') do |f|
          f.write(text)
        end
      rescue Errno::ENOENT
        raise InvalidCache
      end

      # Read from cache when exist
      # @return [Proc,String] parsed JSON content
      def read_from_cache
        if cache.is_a?(Proc)
          cache.call(nil)
        elsif (cache.is_a?(String) || cache.is_a?(Pathname)) &&
              File.exist?(cache)
          open(cache).read
        end
      end

      # Get remote content and store in cache
      # @return [String] unparsed JSON content
      def read_from_url
        text = open_url
        store_in_cache(text) if valid_rates?(text) && cache
        text
      end

      # Opens an url and reads the content
      # @return [String] unparsed JSON content
      def open_url
        open(source_url).read
      rescue OpenURI::HTTPError
        ''
      end

      # Check validity of rates response only for store in cache
      #
      # @example
      #   valid_rates?("{\"quotes\": {\"USDAED\": 3.67304}}")
      #
      # @param [String] text is JSON content
      # @return [Boolean] valid or not
      def valid_rates?(text)
        parsed = JSON.parse(text)
        parsed && parsed.key?('quotes')
      rescue JSON::ParserError
        false
      end

      # Get exchange rates with different strategies
      #
      # @example
      #   exchange_rates(true)
      #   exchange_rates
      #
      # @param straight [Boolean] true for straight, default is careful
      # @return [Hash] key is country code (ISO 3166-1 alpha-3) value Float
      def exchange_rates(straight = false)
        @rates = if straight
                   raw_rates_straight['quotes']
                 else
                   raw_rates_careful['quotes']
                 end
      end

      # Get raw exchange rates from cache and then from url
      # @return [String] JSON content
      def raw_rates_careful(rescue_straight = true)
        JSON.parse(read_from_cache.to_s)
      rescue JSON::ParserError
        rescue_straight ? raw_rates_straight : { 'quotes' => {} }
      end

      # Get raw exchange rates from url
      # @return [String] JSON content
      def raw_rates_straight
        JSON.parse(read_from_url)
      rescue JSON::ParserError
        raw_rates_careful(false)
      end
    end
  end
end
