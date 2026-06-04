require "xml"

module PDF
  module Validate
    # Validates the structure of PDF/A extension schemas embedded in
    # the XMP metadata (ISO 19005-2 § 6.6.2.3). Extension schemas let a
    # document declare XMP properties outside the predefined schemas ;
    # PDF/A constrains their RDF structure tightly.
    #
    # Coverage : § 6.6.2.3.2 (no undefined fields) and § 6.6.2.3.3
    # (the pdfaSchema / pdfaProperty / pdfaType / pdfaField structure —
    # required fields, the internal/external category, and the rdf:Bag
    # container). § 6.6.2.3.1 (every XMP property must belong to a
    # predefined or defined schema) is out of scope — it needs the full
    # list of predefined XMP-2005 schemas.
    #
    # The parser navigates by **namespace URI** rather than by prefix,
    # so locating a field also proves it sits in the right namespace
    # (the "prefix == pdfaSchema" half of each veraPDF test). Both RDF
    # serialisations are handled : a field may be a child element or an
    # attribute of the resource node.
    class XmpExtensionSchema
      EXT_NS      = "http://www.aiim.org/pdfa/ns/extension/"
      SCHEMA_NS   = "http://www.aiim.org/pdfa/ns/schema#"
      PROPERTY_NS = "http://www.aiim.org/pdfa/ns/property#"
      TYPE_NS     = "http://www.aiim.org/pdfa/ns/type#"
      FIELD_NS    = "http://www.aiim.org/pdfa/ns/field#"
      RDF_NS      = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
      XML_NS      = "http://www.w3.org/XML/1998/namespace"

      SCHEMA_FIELDS   = %w[schema namespaceURI prefix property valueType]
      PROPERTY_FIELDS = %w[name valueType category description]
      TYPE_FIELDS     = %w[type namespaceURI prefix description field]
      FIELD_FIELDS    = %w[name valueType description]

      getter violations = [] of String
      # Namespace URIs declared by the document's extension schemas
      # (each pdfaSchema:namespaceURI) — collected during validate.
      getter declared_namespaces = [] of String

      def initialize(@xmp : String)
      end

      def validate : self
        return self unless @xmp.includes?("aiim.org/pdfa/ns/extension")
        document = XML.parse(@xmp)
        containers = [] of XML::Node
        collect_elements(document, EXT_NS, "schemas", containers)
        containers.each { |node| validate_container(node) }
        self
      rescue
        # Malformed XML is reported by the § 6.6.2.1 well-formedness
        # rule, not here.
        self
      end

      # Namespace URIs of every property actually used in the XMP packet
      # — the direct children of each rdf:Description (element form) and
      # its non-RDF/XML attributes (attribute form). Used for § 6.6.2.3.1
      # (every property must belong to a predefined or extension schema).
      # The RDF namespace and the reserved xml namespace are excluded.
      def used_property_namespaces : Array(String)
        result = [] of String
        begin
          document = XML.parse(@xmp)
          descriptions = [] of XML::Node
          collect_elements(document, RDF_NS, "Description", descriptions)
          descriptions.each do |desc|
            desc.children.each do |child|
              next unless child.element?
              ns = child.namespace.try(&.href)
              result << ns if ns && ns != RDF_NS
            end
            desc.attributes.each do |attr|
              ns = attr.namespace.try(&.href)
              next unless ns
              next if ns == RDF_NS || ns == XML_NS
              result << ns
            end
          end
        rescue
          # Malformed XML is reported by the § 6.6.2.1 well-formedness rule.
        end
        result.uniq
      end

      private def validate_container(node : XML::Node) : Nil
        bag = child_element(node, RDF_NS, "Bag")
        unless bag
          @violations << "pdfaExtension:schemas is not an rdf:Bag (§ 6.6.2.3.3 t1)"
          return
        end
        li_items(bag).each { |item| validate_schema(item) }
      end

      private def validate_schema(node : XML::Node) : Nil
        require_field(node, SCHEMA_NS, "schema", "pdfaSchema:schema", "§ 6.6.2.3.3 t2")
        require_field(node, SCHEMA_NS, "namespaceURI", "pdfaSchema:namespaceURI", "§ 6.6.2.3.3 t3")
        require_field(node, SCHEMA_NS, "prefix", "pdfaSchema:prefix", "§ 6.6.2.3.3 t4")

        if declared = field_value(node, SCHEMA_NS, "namespaceURI")
          @declared_namespaces << declared
        end

        if seq = field_seq(node, SCHEMA_NS, "property")
          li_items(seq).each { |item| validate_property(item) }
        end
        if seq = field_seq(node, SCHEMA_NS, "valueType")
          li_items(seq).each { |item| validate_value_type(item) }
        end
        report_undefined(node, SCHEMA_NS, SCHEMA_FIELDS)
      end

      private def validate_property(node : XML::Node) : Nil
        require_field(node, PROPERTY_NS, "name", "pdfaProperty:name", "§ 6.6.2.3.3 t7")
        require_field(node, PROPERTY_NS, "valueType", "pdfaProperty:valueType", "§ 6.6.2.3.3 t8")
        category = field_value(node, PROPERTY_NS, "category")
        if category.nil?
          @violations << "extension property missing pdfaProperty:category (§ 6.6.2.3.3 t9)"
        elsif category != "internal" && category != "external"
          @violations << "extension property category #{category.inspect} must be internal/external (§ 6.6.2.3.3 t9)"
        end
        require_field(node, PROPERTY_NS, "description", "pdfaProperty:description", "§ 6.6.2.3.3 t10")
        report_undefined(node, PROPERTY_NS, PROPERTY_FIELDS)
      end

      private def validate_value_type(node : XML::Node) : Nil
        require_field(node, TYPE_NS, "type", "pdfaType:type", "§ 6.6.2.3.3 t11")
        require_field(node, TYPE_NS, "namespaceURI", "pdfaType:namespaceURI", "§ 6.6.2.3.3 t12")
        require_field(node, TYPE_NS, "prefix", "pdfaType:prefix", "§ 6.6.2.3.3 t13")
        require_field(node, TYPE_NS, "description", "pdfaType:description", "§ 6.6.2.3.3 t14")
        if seq = field_seq(node, TYPE_NS, "field")
          li_items(seq).each { |item| validate_field(item) }
        end
        report_undefined(node, TYPE_NS, TYPE_FIELDS)
      end

      private def validate_field(node : XML::Node) : Nil
        require_field(node, FIELD_NS, "name", "pdfaField:name", "§ 6.6.2.3.3 t16")
        require_field(node, FIELD_NS, "valueType", "pdfaField:valueType", "§ 6.6.2.3.3 t17")
        require_field(node, FIELD_NS, "description", "pdfaField:description", "§ 6.6.2.3.3 t18")
        report_undefined(node, FIELD_NS, FIELD_FIELDS)
      end

      # --- navigation helpers (by namespace URI, both RDF forms) ---

      private def require_field(node : XML::Node, ns : String, local : String, label : String, clause : String) : Nil
        @violations << "extension schema missing #{label} (#{clause})" unless field_present?(node, ns, local)
      end

      private def field_present?(node : XML::Node, ns : String, local : String) : Bool
        return true if child_element(node, ns, local)
        node.attributes.any? { |attr| attr.name == local && attr.namespace.try(&.href) == ns }
      end

      private def field_value(node : XML::Node, ns : String, local : String) : String?
        if element = child_element(node, ns, local)
          return element.content.strip
        end
        node.attributes.each do |attr|
          return attr.content.strip if attr.name == local && attr.namespace.try(&.href) == ns
        end
        nil
      end

      private def field_seq(node : XML::Node, ns : String, local : String) : XML::Node?
        element = child_element(node, ns, local)
        return nil unless element
        child_element(element, RDF_NS, "Seq")
      end

      private def child_element(node : XML::Node, ns : String, local : String) : XML::Node?
        node.children.find do |child|
          child.element? && child.name == local && child.namespace.try(&.href) == ns
        end
      end

      private def li_items(container : XML::Node) : Array(XML::Node)
        container.children.select do |child|
          child.element? && child.name == "li" && child.namespace.try(&.href) == RDF_NS
        end
      end

      # § 6.6.2.3.2 — a resource shall not carry fields of its own
      # PDF/A namespace beyond the defined ones.
      private def report_undefined(node : XML::Node, ns : String, allowed : Array(String)) : Nil
        node.children.each do |child|
          next unless child.element? && child.namespace.try(&.href) == ns
          @violations << "undefined extension-schema field #{child.name} (§ 6.6.2.3.2)" unless allowed.includes?(child.name)
        end
        node.attributes.each do |attr|
          next unless attr.namespace.try(&.href) == ns
          @violations << "undefined extension-schema field #{attr.name} (§ 6.6.2.3.2)" unless allowed.includes?(attr.name)
        end
      end

      private def collect_elements(node : XML::Node, ns : String, local : String, into : Array(XML::Node)) : Nil
        node.children.each do |child|
          next unless child.element?
          into << child if child.name == local && child.namespace.try(&.href) == ns
          collect_elements(child, ns, local, into)
        end
      end
    end
  end
end
