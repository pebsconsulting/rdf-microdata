require 'nokogiri'
require 'rdf/xsd'
require 'json'

module RDF::Microdata
  ##
  # An Microdata parser in Ruby
  #
  # Based on processing rules, amended with the following:
  #
  # @see http://dvcs.w3.org/hg/htmldata/raw-file/0d6b89f5befb/microdata-rdf/index.html
  # @author [Gregg Kellogg](http://greggkellogg.net/)
  class Reader < RDF::Reader
    format Format
    include Expansion
    URL_PROPERTY_ELEMENTS = %w(a area audio embed iframe img link object source track video)
    DEFAULT_REGISTRY = File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "etc", "registry.json"))

    # @private
    class CrawlFailure < StandardError; end

    # @!attribute [r] implementation
    # @return [Module] Returns the HTML implementation module for this reader instance.
    attr_reader :implementation

    ##
    # Accumulated errors found during processing
    # @return [Array<String>]
    attr_reader :errors

    ##
    # Returns the base URI determined by this reader.
    #
    # @example
    #   reader.prefixes[:dc]  #=> RDF::URI('http://purl.org/dc/terms/')
    #
    # @return [Hash{Symbol => RDF::URI}]
    # @since  0.3.0
    def base_uri
      @options[:base_uri]
    end

    # Interface to registry
    class Registry
      # @return [RDF::URI] Prefix of vocabulary
      attr_reader :uri

      # @return [Hash] properties
      attr_reader :properties

      ##
      # Initialize the registry from a URI or file path
      #
      # @param [String] registry_uri
      def self.load_registry(registry_uri)
        return if @registry_uri == registry_uri

        json = RDF::Util::File.open_file(registry_uri) { |f| JSON.load(f) }

        @prefixes = {}
        json.each do |prefix, elements|
          next unless elements.is_a?(Hash)
          properties = elements.fetch("properties", {})
          @prefixes[prefix] = Registry.new(prefix, properties)
        end
        @registry_uri = registry_uri
      end

      ##
      # Initialize registry for a particular prefix URI
      #
      # @param [RDF::URI] prefixURI
      # @param [Hash] properties ({})
      def initialize(prefixURI, properties = {})
        @uri = prefixURI
        @properties = properties
        @property_base = prefixURI.to_s
        # Append a '#' for fragment if necessary
        @property_base += '#' unless %w(/ #).include?(@property_base[-1,1])
      end

      ##
      # Find a registry entry given a type URI
      #
      # @param [RDF::URI] type
      # @return [Registry]
      def self.find(type) 
        @prefixes ||= {}
        k = @prefixes.keys.detect {|key| type.to_s.index(key) == 0 }
        @prefixes[k] if k
      end
      
      ##
      # Generate a predicateURI given a `name`
      #
      # @param [#to_s] name
      # @param [Hash{}] ec Evaluation Context
      # @return [RDF::URI]
      def predicateURI(name, ec)
        u = RDF::URI(name)
        # 1) If _name_ is an _absolute URL_, return _name_ as a _URI reference_
        return u if u.absolute?
        
        n = frag_escape(name)
        if ec[:current_type].nil?
          # 2) If current type from context is null, there can be no current vocabulary.
          #    Return the URI reference that is the document base with its fragment set to the fragment-escaped value of name
          u = RDF::URI(ec[:document_base].to_s)
          u.fragment = frag_escape(name)
          u
        else
          # 4) If scheme is vocabulary return the URI reference constructed by appending the fragment escaped value of name to current vocabulary, separated by a U+0023 NUMBER SIGN character (#) unless the current vocabulary ends with either a U+0023 NUMBER SIGN character (#) or SOLIDUS U+002F (/).
          RDF::URI(@property_base + n)
        end
      end

      ##
      # Yield a equivalentProperty or subPropertyOf if appropriate
      #
      # @param [RDF::URI] predicateURI
      # @yield equiv
      # @yieldparam [RDF::URI] equiv
      def expand(predicateURI)
        tok = tokenize(predicateURI)
        if @properties[tok].is_a?(Hash)
          value = @properties[tok].fetch("subPropertyOf", nil)
          value ||= @properties[tok].fetch("equivalentProperty", nil)

          Array(value).each {|equiv| yield RDF::URI(equiv)}
        end
      end

      ##
      # Turn a predicateURI into a simple token
      # @param [RDF::URI] predicateURI
      # @return [String]
      def tokenize(predicateURI)
        predicateURI.to_s.sub(@property_base, '')
      end

      ##
      # Fragment escape a name
      def frag_escape(name)
        name.to_s.gsub(/["#%<>\[\\\]^{|}]/) {|c| '%' + c.unpack('H2' * c.bytesize).join('%').upcase}
      end
    end

    ##
    # Initializes the Microdata reader instance.
    #
    # @param  [Nokogiri::HTML::Document, Nokogiri::XML::Document, IO, File, String] input
    #   the input stream to read
    # @param  [Hash{Symbol => Object}] options
    #   any additional options
    # @option options [Encoding] :encoding     (Encoding::UTF_8)
    #   the encoding of the input stream (Ruby 1.9+)
    # @option options [Boolean]  :validate     (false)
    #   whether to validate the parsed statements and values
    # @option options [Boolean]  :canonicalize (false)
    #   whether to canonicalize parsed literals
    # @option options [Boolean]  :intern       (true)
    #   whether to intern all parsed URIs
    # @option options [#to_s]    :base_uri     (nil)
    #   the base URI to use when resolving relative URIs
    # @option options [#to_s]    :registry
    # @option options [Array] :errors
    #   array for placing errors found when parsing
    # @option options [Array] :debug
    #   Array to place debug messages
    # @return [reader]
    # @yield  [reader] `self`
    # @yieldparam  [RDF::Reader] reader
    # @yieldreturn [void] ignored
    # @raise [Error] Raises `RDF::ReaderError` when validating
    def initialize(input = $stdin, options = {}, &block)
      super do
        @errors = @options[:errors]
        @warnings = @options[:warnings]
        @debug = options[:debug]

        @library = :nokogiri

        require "rdf/microdata/reader/#{@library}"
        @implementation = Nokogiri
        self.extend(@implementation)

        initialize_html(input, options) rescue raise RDF::ReaderError.new($!.message)

        if (root.nil? && validate?)
          raise RDF::ReaderError, "Empty Document"
        end
        errors = doc_errors.reject {|e| e.to_s =~ /Tag (audio|source|track|video|time) invalid/}
        raise RDF::ReaderError, "Syntax errors:\n#{errors}" if !errors.empty? && validate?

        add_debug(@doc, "library = #{@library}")

        # Load registry
        begin
          registry_uri = options[:registry] || DEFAULT_REGISTRY
          add_debug(@doc, "registry = #{registry_uri.inspect}")
          Registry.load_registry(registry_uri)
        rescue JSON::ParserError => e
          raise RDF::ReaderError, "Failed to parse registry: #{e.message}"
        end
        
        if block_given?
          case block.arity
            when 0 then instance_eval(&block)
            else block.call(self)
          end
        end
      end
    end

    ##
    # Iterates the given block for each RDF statement in the input.
    #
    # Reads to graph and performs expansion if required.
    #
    # @yield  [statement]
    # @yieldparam [RDF::Statement] statement
    # @return [void]
    def each_statement(&block)
      if block_given?
        @callback = block

        # parse
        parse_whole_document(@doc, base_uri)
      end
      enum_for(:each_statement)
    end

    ##
    # Iterates the given block for each RDF triple in the input.
    #
    # @yield  [subject, predicate, object]
    # @yieldparam [RDF::Resource] subject
    # @yieldparam [RDF::URI]      predicate
    # @yieldparam [RDF::Value]    object
    # @return [void]
    def each_triple(&block)
      if block_given?
        each_statement do |statement|
          block.call(*statement.to_triple)
        end
      end
      enum_for(:each_triple)
    end
    
    private

    # Keep track of allocated BNodes
    def bnode(value = nil)
      @bnode_cache ||= {}
      @bnode_cache[value.to_s] ||= RDF::Node.new(value)
    end
    
    # Figure out the document path, if it is an Element or Attribute
    def node_path(node)
      "<#{base_uri}>#{node.respond_to?(:display_path) ? node.display_path : node}"
    end

    ##
    # Add debug event to debug array, if specified
    #
    # @param [Nokogiri::XML::Node, #to_s] node XML Node or string for showing context
    #
    # @param [String] message
    # @yieldreturn [String] appended to message, to allow for lazy-evaulation of message
    def add_debug(node, message = "")
      return unless ::RDF::Microdata.debug? || @debug
      message = message + yield if block_given?
      puts "#{node_path(node)}: #{message}" if ::RDF::Microdata::debug?
      @debug << "#{node_path(node)}: #{message}" if @debug.is_a?(Array)
    end

    def add_error(node, message)
      @errors << "#{node_path(node)}: #{message}" if @errors
      add_debug(node, message)
      raise RDF::ReaderError, message if validate?
    end
    
    ##
    # add a statement, object can be literal or URI or bnode
    #
    # @param [Nokogiri::XML::Node, any] node XML Node or string for showing context
    #
    # @param [URI, BNode] subject the subject of the statement
    # @param [URI] predicate the predicate of the statement
    # @param [URI, BNode, Literal] object the object of the statement
    # @return [Statement] Added statement
    # @raise [ReaderError] Checks parameter types and raises if they are incorrect if parsing mode is _validate_.
    def add_triple(node, subject, predicate, object)
      statement = RDF::Statement.new(subject, predicate, object)
      raise RDF::ReaderError, "#{statement.inspect} is invalid" if validate? && statement.invalid?
      add_debug(node) {"statement: #{RDF::NTriples.serialize(statement)}"}
      @callback.call(statement)
    end

    # Parsing a Microdata document (this is *not* the recursive method)
    def parse_whole_document(doc, base)
      base = doc_base(base)
      options[:base_uri] = if (base)
        # Strip any fragment from base
        base = base.to_s.split('#').first
        base = uri(base)
      else
        base = RDF::URI("")
      end
      
      add_debug(nil) {"parse_whole_doc: base='#{base}'"}

      ec = {
        :memory             => {},
        :current_type       => nil,
        current_vocabulary: nil,
        :document_base      => base,
      }
      # 1) For each element that is also a top-level item, Generate the triples for that item using the evaluation context.
      getItems.each do |el|
        generate_triples(el, ec)
      end

      add_debug(doc, "parse_whole_doc: traversal complete")
    end

    ##
    # Generate triples for an item
    #
    # @param [RDF::Resource] item
    # @param [Hash{Symbol => Object}] ec
    # @option ec [Hash{Nokogiri::XML::Element} => RDF::Resource] memory
    # @option ec [RDF::Resource] :current_type
    # @return [RDF::Resource]
    def generate_triples(item, ec = {})
      memory = ec[:memory]
      # 1) If there is an entry for item in memory, then let subject be the subject of that entry. Otherwise, if item has a global identifier and that global identifier is an absolute URL, let subject be that global identifier. Otherwise, let subject be a new blank node.
      subject = if memory.include?(item.node)
        memory[item.node][:subject]
      elsif item.has_attribute?('itemid')
        uri(item.attribute('itemid'), item.base || base_uri)
      end || RDF::Node.new
      memory[item.node] ||= {}

      add_debug(item) {"gentrips(2): subject=#{subject.inspect}, current_type: #{ec[:current_type]}"}

      # 2) Add a mapping from item to subject in memory, if there isn't one already.
      memory[item.node][:subject] ||= subject
      
      # 3) For each type returned from element.itemType of the element defining the item.
      type = nil
      item.attribute('itemtype').to_s.split(' ').map{|n| uri(n)}.select(&:absolute?).each do |t|
        #   3.1. If type is an absolute URL, generate the following triple:
        type ||= t
        add_triple(item, subject, RDF.type, t)
      end

      # 4) Set type to the first value returned from element.itemType of the element defining the item.

      # 5) Otherwise, set type to current type from the Evaluation Context if not empty.
      type ||= ec[:current_type]
      add_debug(item)  {"gentrips(5): type=#{type.inspect}"}

      # 6) If the registry contains a URI prefix that is a character for character match of type up to the length of the URI prefix, set vocab as that URI prefix.
      vocab = Registry.find(type)

      # 7) Otherwise, if type is not empty, construct vocab by removing everything following the last SOLIDUS U+002F ("/") or NUMBER SIGN U+0023 ("#") from the path component of type.
      vocab ||= begin
        type_vocab = type.to_s.sub(/([\/\#])[^\/\#]*$/, '\1')
        add_debug(item)  {"gentrips(7): type_vocab=#{type_vocab.inspect}"}
        Registry.new(type_vocab)
      end

      # 8) Update evaluation context setting current vocabulary to vocab.
      ec[:current_vocabulary] = vocab

      # 9. For each element _element_ that has one or more property names and is one of the properties of the item _item_, run the following substep:
      props = item_properties(item)
      # 9.1. For each name name in element's property names, run the following substeps:
      props.each do |element|
        element.attribute('itemprop').to_s.split(' ').compact.each do |name|
          add_debug(item) {"gentrips(9.1): name=#{name.inspect}, type=#{type}"}
          # 9.1.1) Let context be a copy of evaluation context with current type set to type and current vocabulary set to vocab.
          ec_new = ec.merge({current_type: type, current_vocabulary: vocab})
          
          # 9.1.2) Let predicate be the result of generate predicate URI using context and name. Update context by setting current name to predicate.
          predicate = vocab.predicateURI(name, ec_new)

          # 9.1.3) Let value be the property value of element.
          value = property_value(element)
          add_debug(item) {"gentrips(9.1.3) value=#{value.inspect}"}
          
          # 9.1.4) If value is an item, then generate the triples for value context. Replace value by the subject returned from those steps.
          if value.is_a?(Hash)
            value = generate_triples(element, ec_new) 
            add_debug(item) {"gentrips(9.1.4): value=#{value.inspect}"}
          end

          # 9.1.4) Generate the following triple:
          add_triple(item, subject, predicate, value)

          # 9.1.5) If an entry exists in the registry for name in the vocabulary associated with vocab having the key subPropertyOf or equivalentProperty
          vocab.expand(predicate) do |equiv|
            add_debug(item) {"gentrips(9.1.5): equiv=#{equiv.inspect}"}
            # for each such value equiv, generate the following triple
            add_triple(item, subject, equiv, value)
          end 
        end
      end

      # 10. For each element element that has one or more reverse property names and is one of the reverse properties of the item item, run the following substep:
      props = item_properties(item, true)
      # 10.1. For each name name in element's reverse property names, run the following substeps:
      props.each do |element|
        element.attribute('itemprop-reverse').to_s.split(' ').compact.each do |name|
          add_debug(item) {"gentrips(10.1): name=#{name.inspect}"}
          # 10.1.1) Let context be a copy of evaluation context with current type set to type and current vocabulary set to vocab.
          ec_new = ec.merge({current_type: type, current_vocabulary: vocab})
          
          # 10.1.2) Let predicate be the result of generate predicate URI using context and name. Update context by setting current name to predicate.
          predicate = vocab.predicateURI(name, ec_new)
          
          # 10.1.3) Let value be the property value of element.
          value = property_value(element)
          add_debug(item) {"gentrips(10.1.3) value=#{value.inspect}"}

          # 10.1.4) If value is an item, then generate the triples for value context. Replace value by the subject returned from those steps.
          if value.is_a?(Hash)
            value = generate_triples(element, ec_new) 
            add_debug(item) {"gentrips(10.1.4): value=#{value.inspect}"}
          elsif value.is_a?(RDF::Literal)
            # 10.1.5) Otherwise, if value is a literal, ignore the value and continue to the next name; it is an error for the value of @itemprop-reverse to be a literal
            add_error(element, "Value of @itemprop-reverse may not be a literal: #{value.inspect}")
            next
          end

          # 10.1.6) Generate the following triple
          add_triple(item, value, predicate, subject)
        end
      end

      # 11) Return subject
      subject
    end

    ##
    # To find the properties of an item defined by the element root, the user agent must try to crawl the properties of the element root, with an empty list as the value of memory: if this fails, then the properties of the item defined by the element root is an empty list; otherwise, it is the returned list.
    #
    # @param [Nokogiri::XML::Element] item
    # @param [Boolean] reverse (false) return reverse properties
    # @return [Array<Nokogiri::XML::Element>]
    #   List of property elements for an item
    def item_properties(item, reverse = false)
      add_debug(item, "item_properties (#{reverse.inspect})")
      crawl_properties(item, [], reverse)
    rescue CrawlFailure => e
      add_error(item, e.message)
      return []
    end
    
    ##
    # To crawl the properties of an element root with a list memory, the user agent must run the following steps. These steps either fail or return a list with a count of errors. The count of errors is used as part of the authoring conformance criteria below.
    #
    # @param [Nokogiri::XML::Element] root
    # @param [Array<Nokokogiri::XML::Element>] memory
    # @param [Boolean] reverse crawl reverse properties
    # @return [Array<Nokogiri::XML::Element>]
    #   Resultant elements
    def crawl_properties(root, memory, reverse)
      # 1. If root is in memory, then the algorithm fails; abort these steps.
      raise CrawlFailure, "crawl_props mem already has #{root.inspect}" if memory.include?(root)
      
      # 2. Collect all the elements in the item root; let results be the resulting list of elements, and errors be the resulting count of errors.
      results = elements_in_item(root)
      add_debug(root) {"crawl_properties reverse=#{reverse.inspect} results=#{results.map {|e| node_path(e)}.inspect}"}

      # 3. Remove any elements from results that do not have an @itemprop (@itemprop-reverse) attribute specified.
      results = results.select {|e| e.has_attribute?(reverse ? 'itemprop-reverse' : 'itemprop')}
      
      # 4. Let new memory be a new list consisting of the old list memory with the addition of root.
      raise CrawlFailure, "itemref recursion" if memory.detect {|n| root.node.object_id == n.node.object_id}
      new_memory = memory + [root]
      
      # 5. For each element in results that has an @itemscope attribute specified, crawl the properties of the element, with new memory as the memory.
      results.select {|e| e.has_attribute?('itemscope')}.each do |element|
        crawl_properties(element, new_memory, reverse)
      end
      
      results
    end

    ##
    # To collect all the elements in the item root, the user agent must run these steps. They return a list of elements.
    #
    # @param [Nokogiri::XML::Element] root
    # @return [Array<Nokogiri::XML::Element>]
    #   Resultant elements and error count
    # @raise [CrawlFailure] on element recursion
    def elements_in_item(root)
      # Let results and pending be empty lists of elements.
      # Let errors be zero.
      results, memory, errors = [], [], 0
      
      # Add all the children elements of root to pending.
      pending = root.elements
      
      # If root has an itemref attribute, split the value of that itemref attribute on spaces.
      # For each resulting token ID, 
      root.attribute('itemref').to_s.split(' ').each do |id|
        add_debug(root) {"elements_in_item itemref id #{id}"}
        # if there is an element in the home subtree of root with the ID ID,
        # then add the first such element to pending.
        id_elem = find_element_by_id(id)
        pending << id_elem if id_elem
      end
      add_debug(root) {"elements_in_item pending #{pending.inspect}"}

      # Loop: Remove an element from pending and let current be that element.
      while current = pending.shift
        if memory.include?(current)
          raise CrawlFailure, "elements_in_item: results already includes #{current.inspect}"
        elsif !current.has_attribute?('itemscope')
          # If current is not already in results and current does not have an itemscope attribute, then: add all the child elements of current to pending.
          pending += current.elements
        end
        memory << current
        
        # If current is not already in results, then: add current to results.
        results << current unless results.include?(current)
      end

      results
    end

    ##
    #
    def property_value(element)
      base = element.base || base_uri
      add_debug(element) {"property_value(#{element.name}): base #{base.inspect}"}
      value = case
      when element.has_attribute?('itemscope')
        {}
      when element.name == 'meta'
        RDF::Literal.new(element.attribute('content').to_s, language: element.language)
      when %w(data meter).include?(element.name) && element.attribute('value')
        # Lexically scan value and assign appropriate type, otherwise, leave untyped
        v = element.attribute('value').to_s
        datatype = %w(Integer Float Double).map {|t| RDF::Literal.const_get(t)}.detect do |dt|
          v.match(dt::GRAMMAR)
        end || RDF::Literal
        datatype = RDF::Literal::Double if datatype == RDF::Literal::Float
        datatype.new(v)
      when %w(audio embed iframe img source track video).include?(element.name)
        uri(element.attribute('src'), base)
      when %w(a area link).include?(element.name)
        uri(element.attribute('href'), base)
      when %w(object).include?(element.name)
        uri(element.attribute('data'), base)
      when %w(time).include?(element.name)
        # Lexically scan value and assign appropriate type, otherwise, leave untyped
        v = (element.attribute('datetime') || element.text).to_s
        datatype = %w(Date Time DateTime Duration).map {|t| RDF::Literal.const_get(t)}.detect do |dt|
          v.match(dt::GRAMMAR)
        end || RDF::Literal
        datatype.new(v, language: element.language)
      else
        RDF::Literal.new(element.inner_text, language: element.language)
      end
      add_debug(element) {"  #{value.inspect}"}
      value
    end

    # Fixme, what about xml:base relative to element?
    def uri(value, base = nil)
      value = if base
        base = uri(base) unless base.is_a?(RDF::URI)
        base.join(value.to_s)
      else
        RDF::URI(value.to_s)
      end
      value.validate! if validate?
      value.canonicalize! if canonicalize?
      value = RDF::URI.intern(value) if intern?
      value
    end
  end
end