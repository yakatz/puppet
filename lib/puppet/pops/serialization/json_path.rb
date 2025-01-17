# frozen_string_literal: true
require_relative '../../../puppet/concurrent/thread_local_singleton'

module Puppet::Pops
module Serialization
module JsonPath
  # Creates a _json_path_ reference from the given `path` argument
  #
  # @path path [Array<Integer,String>] An array of integers and strings
  # @return [String] the created json_path
  #
  # @api private
  def self.to_json_path(path)
    p = '$'.dup
    path.each do |seg|
      if seg.nil?
        p << '[null]'
      elsif Types::PScalarDataType::DEFAULT.instance?(seg)
        p << '[' << Types::StringConverter.singleton.convert(seg, '%p') << ']'
      else
        # Unable to construct json path from complex segments
        return nil
      end
    end
    p
  end

  # Resolver for JSON path that uses the Puppet parser to create the AST. The path must start
  # with '$' which denotes the value that is passed into the parser. This parser can easily
  # be extended with more elaborate resolution mechanisms involving document sets.
  #
  # The parser is limited to constructs generated by the {JsonPath#to_json_path}
  # method.
  #
  # @api private
  class Resolver
    extend Puppet::Concurrent::ThreadLocalSingleton

    def initialize
      @parser = Parser::Parser.new
      @visitor = Visitor.new(nil, 'resolve', 2, 2)
    end

    # Resolve the given _path_ in the given _context_.
    # @param context [Object] the context used for resolution
    # @param path [String] the json path
    # @return [Object] the resolved value
    #
    def resolve(context, path)
      factory = @parser.parse_string(path)
      v = resolve_any(factory.model.body, context, path)
      v.is_a?(Builder) ? v.resolve : v
    end

    def resolve_any(ast, context, path)
      @visitor.visit_this_2(self, ast, context, path)
    end

    def resolve_AccessExpression(ast, context, path)
      bad_json_path(path) unless ast.keys.size == 1
      receiver = resolve_any(ast.left_expr, context, path)
      key = resolve_any(ast.keys[0], context, path)
      if receiver.is_a?(Types::PuppetObject)
        PCORE_TYPE_KEY == key ? receiver._pcore_type : receiver.send(key)
      else
        receiver[key]
      end
    end

    def resolve_NamedAccessExpression(ast, context, path)
      receiver = resolve_any(ast.left_expr, context, path)
      key = resolve_any(ast.right_expr, context, path)
      if receiver.is_a?(Types::PuppetObject)
        PCORE_TYPE_KEY == key ? receiver._pcore_type : receiver.send(key)
      else
        receiver[key]
      end
    end

    def resolve_QualifiedName(ast, _, _)
      v = ast.value
      'null' == v ? nil : v
    end

    def resolve_QualifiedReference(ast, _, _)
      v = ast.cased_value
      'null'.casecmp(v) == 0 ? nil : v
    end

    def resolve_ReservedWord(ast, _, _)
      ast.word
    end

    def resolve_LiteralUndef(_, _, _)
      'undef'
    end

    def resolve_LiteralDefault(_, _, _)
      'default'
    end

    def resolve_VariableExpression(ast, context, path)
      # A single '$' means root, i.e. the context.
      bad_json_path(path) unless EMPTY_STRING == resolve_any(ast.expr, context, path)
      context
    end

    def resolve_CallMethodExpression(ast, context, path)
      bad_json_path(path) unless ast.arguments.empty?
      resolve_any(ast.functor_expr, context, path)
    end

    def resolve_LiteralValue(ast, _, _)
      ast.value
    end

    def resolve_Object(ast, _, path)
      bad_json_path(path)
    end

    def bad_json_path(path)
      raise SerializationError, _('Unable to parse jsonpath "%{path}"') % { :path => path }
    end
    private :bad_json_path
  end
end
end
end
