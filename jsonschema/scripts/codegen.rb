require 'json'
require 'erb'
require 'set'

class Codegen
  TEMPLATES_DIRECTORY = "#{File.dirname(__FILE__)}/templates/"

  def initialize(paths, language_type_by_schema_type)
    @paths = paths
    @language_type_by_schema_type = language_type_by_schema_type

    @schemas = {}
    @enum_set = Set.new

    @paths.each do |path|
      expanded_path = File.expand_path(path)
      begin
        schema = JSON.parse(File.read(path))
        add_schema(expanded_path, schema)
      rescue => e
        e.message << "\npath: #{path}"
        raise e
      end
    end

    @schemas = @schemas.sort
    @enums = @enum_set.to_a.sort{|a,b| a[:name] <=> b[:name]}
  end

  def generate(template_name)
    template_source = File.read("#{TEMPLATES_DIRECTORY}/#{template_name}")
    template = ERB.new(template_source, nil, '-')
    STDOUT.write template.result(binding)
  end

  def add_schema(key, schema)
    @schemas[key] = schema
    (schema['definitions'] || {}).each do |name, subschema|
      subkey = "#{key}/#{name}"
      add_schema(subkey, subschema)
    end

    schema['properties'].each do |property_name, property|
      enum = property['enum']
      if enum
        parent_type_name = class_name(key)
        enum_name(parent_type_name, property_name, enum)
      end
    end
  end

  def native_type?(type_name)
    STDERR.puts "NATIVE #{type_name}"
    @language_type_by_schema_type.values.include?(type_name)
  end

  def default_value(parent_type_name, property_name, property)
    if property['items']
      '[]'
    elsif property['type'] == 'string'
      if property['enum']
        enum_type_name = type_for(parent_type_name, property_name, property)
        default_enum(enum_type_name, property)
      else
        "''"
      end
    elsif property['type'] == 'integer'
      "0"
    elsif property['type'] == 'boolean'
      "false"
    elsif property['$ref']
      type = type_for(parent_type_name, nil, property)
      "new #{type}()"
    else
      raise "Cannot create default value for #{parent_type_name}##{property.to_json}"
    end
  end

  def default_enum(enum_type_name, property)
    "#{enum_type_name}.#{enum_constant(property['enum'][0])}"
  end

  def enum_constant(value)
    value.gsub(/[\.\/\+]/, '_').upcase
  end

  def type_for(parent_type_name, property_name, property)
    ref = property['$ref']
    type = property['type']
    items = property['items']
    enum = property['enum']

    if ref
      property_type_from_ref(property['$ref'])
    elsif type
      if type == 'array'
        array_type_for(type_for(parent_type_name, nil, items))
      else
        raise "No type mapping for JSONSchema type #{type}. Schema:\n#{JSON.pretty_generate(property)}" unless @language_type_by_schema_type[type]
        if enum
          enum_type_name = enum_name(parent_type_name, property_name, enum)
          property_type_from_enum(enum_type_name)
        else
          @language_type_by_schema_type[type]
        end
      end
    else
      # Inline schema (not supported)
      raise "Property #{name} did not define 'type' or '$ref'"
    end
  end

  def property_type_from_ref(ref)
    class_name(ref)
  end

  def property_type_from_enum(enum)
    enum
  end

  def enum_name(parent_type_name, property_name, enum)
    enum_type_name = "#{parent_type_name}#{capitalize(property_name)}"
    @enum_set.add({ name: enum_type_name, values: enum })
    enum_type_name
  end

  def class_name(ref)
    File.basename(ref, '.json')
  end

  def capitalize(s)
    s.sub(/./,&:upcase)
  end

  # Thank you very much rails!
  # https://github.com/rails/rails/blob/v6.1.3.2/activesupport/lib/active_support/inflector/methods.rb#L92
  def underscore(camel_cased_word)
    return camel_cased_word unless /[A-Z-]/.match?(camel_cased_word)
    word = camel_cased_word.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
    word.gsub!(/([a-z\d])([A-Z])/, '\1_\2')
    word.tr!("-", "_")
    word.downcase!
    word
  end
end

class TypeScript < Codegen
  def initialize(paths)
    language_type_by_schema_type = {
      'integer' => 'number',
      'string' => 'string',
      'boolean' => 'boolean',
    }

    super(paths, language_type_by_schema_type)
  end

  def array_type_for(type_name)
    "readonly #{type_name}[]"
  end
end

class Java < Codegen
  def initialize(paths)
    language_type_by_schema_type = {
      'integer' => 'Long',
      'string' => 'String',
      'boolean' => 'Boolean',
    }

    super(paths, language_type_by_schema_type)
  end

  def array_type_for(type_name)
    "java.util.List<#{type_name}>"
  end

  def format_description(raw_description, indent_string: "")
    return '' if raw_description.nil?

    raw_description
      .split("\n")
      .map { |line| line.strip() }
      .filter { |line| line != '*' }
      .map { |line| " * #{line}".rstrip() }
      .join("\n#{indent_string}")
  end
end

class Perl < Codegen
  def initialize(paths)
    language_type_by_schema_type = {
      'integer' => 'number',
      'string' => 'string',
      'boolean' => 'boolean',
    }

    super(paths, language_type_by_schema_type)
  end

  def array_type_for(type_name)
    "[]#{type_name}"
  end

  def default_value(parent_type_name, property_name, property)
    if property['type'] == 'string'
      if property['enum']
        "#{property_name.upcase}_#{enum_constant(property['enum'][0])}"
      else
        "''"
      end
    elsif property['type'] == 'boolean'
      "''"  # an empty string renders evaluates to false
    elsif property['$ref']
      type = type_for(parent_type_name, nil, property)
      "#{type}->new()"
    else
      super(parent_type_name, property_name, property)
    end
  end

  def property_type_from_ref(ref)
    "Cucumber::Messages::#{class_name(ref)}"
  end

  def property_type_from_enum(enum)
    ''
  end

  def format_description(raw_description)
    return '' if raw_description.nil?

    raw_description
      .split("\n")
      .map { |description_line| "#{description_line}" }
      .join("\n")
  end
end

class Ruby < Codegen
  def initialize(paths)
    language_type_by_schema_type = {
      'integer' => 'number',
      'string' => 'string',
      'boolean' => 'boolean',
    }

    super(paths, language_type_by_schema_type)
  end

  def array_type_for(type_name)
    "[]"
  end

  def default_value(parent_type_name, property_name, property)
    if property['type'] == 'string'
      if property['enum']
        enum_type_name = type_for(parent_type_name, property_name, property)
        "#{enum_type_name}::#{enum_constant(property['enum'][0])}"
      else
        "''"
      end
    elsif property['$ref']
      type = type_for(parent_type_name, nil, property)
      "#{type}.new"
    else
      super(parent_type_name, property_name, property)
    end
  end

  def format_description(raw_description, indent_string: "    ")
    return '' if raw_description.nil?

    raw_description
      .split("\n")
      .map { |description_line| "# #{description_line}" }
      .join("\n#{indent_string}")
  end
end

class Go < Codegen
  def initialize(paths)
    language_type_by_schema_type = {
      'integer' => 'int64',
      'string' => 'string',
      'boolean' => 'bool',
    }
    super(paths, language_type_by_schema_type)
  end

  def property_type_from_ref(ref)
    "*#{class_name(ref)}"
  end

  def array_type_for(type_name)
    "[]#{type_name}"
  end
end

class Markdown < Codegen
  def initialize(paths)
    language_type_by_schema_type = {
      'integer' => 'integer',
      'string' => 'string',
      'boolean' => 'boolean',
    }
    super(paths, language_type_by_schema_type)
  end

  def property_type_from_ref(ref)
    "[#{class_name(ref)}](##{class_name(ref).downcase})"
  end

  def property_type_from_enum(enum)
    "[#{enum}](##{enum.downcase})"
  end

  def array_type_for(type_name)
    "#{type_name}[]"
  end
end

class Php < Codegen
  def initialize(paths)
    language_type_by_schema_type = {
      'string' => 'string',
      'integer' => 'int',
      'boolean' => 'bool',
    }
    super(paths, language_type_by_schema_type)
  end

  def format_description(raw_description, indent_string: "        ")
    return '' if raw_description.nil?

    raw_description
      .split("\n")
      .map { |line| line.strip() }
      .filter { |line| line != '*' }
      .map { |line| " * #{line}".rstrip() }
      .join("\n#{indent_string}")
  end

  def array_type_for(type_name)
    "array"
  end

  def enum_name(parent_type_name, property_name, enum)
    enum_type_name = "#{class_name(parent_type_name)}\\#{capitalize(property_name)}"
    @enum_set.add({ name: enum_type_name, values: enum })
    enum_type_name
  end

  def array_contents_type(parent_type_name, property_name, property)
    type_for(parent_type_name, nil, property['items'])
  end

  def is_nullable(property_name, schema)
    !(schema['required'] || []).index(property_name)
  end

  def is_scalar(property)
    property.has_key?('type') && @language_type_by_schema_type.has_key?(property['type'])
  end

  def scalar_type_for(property)
    raise "No type mapping for JSONSchema type #{type}. Schema:\n#{JSON.pretty_generate(property)}" unless @language_type_by_schema_type[property['type']]

    @language_type_by_schema_type[property['type']]
  end

  def constructor_for(parent_type, property, property_name, schema, arr_name)
    constr = non_nullable_constructor_for(parent_type, property, property_name, schema, arr_name)

    is_nullable(property_name, schema) ? "isset($#{arr_name}['#{property_name}']) ? #{constr} : null" : constr
  end

  def non_nullable_constructor_for(parent_type, property, property_name, schema, arr_name)
    source = property_name.nil? ? "#{arr_name}" : "#{arr_name}['#{property_name}']"
    if is_scalar(property)
      if property['enum']
        "#{enum_name(parent_type, property_name, property['enum'])}::from((#{scalar_type_for(property)}) $#{source})"
      else
        "(#{scalar_type_for(property)}) $#{source}"
      end
    else
      type = type_for(parent_type, property_name, property)
      if type == 'array'
        constructor = non_nullable_constructor_for(parent_type, property['items'], nil, schema, "member")
        member_type = (property['items']['type'] ? 'mixed' : 'array')
        "array_values(array_map(fn (#{member_type} $member) => #{constructor}, $#{source}))"
      else
        "#{type_for(parent_type, property_name, property)}::fromArray($#{source})"
      end
    end
  end

  def default_value(class_name, property_name, property, schema)
	if is_nullable(property_name, schema)
	  return 'null'
	end

	super(class_name, property_name, property)
  end

  def default_enum(enum_type_name, property)
    "#{enum_type_name}::#{enum_constant(property['enum'][0])}"
  end
end


clazz = Object.const_get(ARGV[0])
path = ARGV[1]
paths = File.file?(path) ? [path] : Dir["#{path}/*.json"]
codegen = clazz.new(paths)
template_name = ARGV[2]
codegen.generate(template_name)
