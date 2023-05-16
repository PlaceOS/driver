require "json"

class Object
  # :nodoc:
  def try_to_json(fallback = nil)
    {% begin %}
      {% if @type.ancestors.includes?(Number) %}
         return self.to_json
      {% end %}
      {% for m in @type.methods %}
        {% if m.name == "to_json" %}
          {% if m.args.size == 1 %}
            {% if m.args[0].restriction.stringify == "JSON::Builder" %}
              return self.to_json
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    fallback
  end
end

# NOTE:: fixes issues with Crystal 1.5.0
# TODO:: remove once this is mainline: https://github.com/crystal-lang/crystal/pull/12497
{% if compare_versions(Crystal::VERSION, "1.5.2") < 0 %}
{% if compare_versions(Crystal::VERSION, "1.5.0") >= 0 %}
require "crystal/dwarf/info"

# debugging dwarf file issues
struct Crystal::DWARF::Info
  private def read_attribute_value(form, attr)
    case form
    when FORM::Addr
      case address_size
      when 4 then @io.read_bytes(UInt32)
      when 8 then @io.read_bytes(UInt64)
      else        raise "Invalid address size: #{address_size}"
      end
    when FORM::Block1
      len = @io.read_byte.not_nil!
      @io.read_fully(bytes = Bytes.new(len.to_i))
      bytes
    when FORM::Block2
      len = @io.read_bytes(UInt16)
      @io.read_fully(bytes = Bytes.new(len.to_i))
      bytes
    when FORM::Block4
      len = @io.read_bytes(UInt32)
      @io.read_fully(bytes = Bytes.new(len.to_i64))
      bytes
    when FORM::Block
      len = DWARF.read_unsigned_leb128(@io)
      @io.read_fully(bytes = Bytes.new(len))
      bytes
    when FORM::Data1
      @io.read_byte.not_nil!
    when FORM::Data2
      @io.read_bytes(UInt16)
    when FORM::Data4
      @io.read_bytes(UInt32)
    when FORM::Data8
      @io.read_bytes(UInt64)
    when FORM::Data16
      @io.read_bytes(UInt64)
      @io.read_bytes(UInt64)
    when FORM::Sdata
      DWARF.read_signed_leb128(@io)
    when FORM::Udata
      DWARF.read_unsigned_leb128(@io)
    when FORM::ImplicitConst
      attr.value
    when FORM::Exprloc
      len = DWARF.read_unsigned_leb128(@io)
      @io.read_fully(bytes = Bytes.new(len))
      bytes
    when FORM::Flag
      @io.read_byte == 1
    when FORM::FlagPresent
      true
    when FORM::SecOffset
      read_ulong
    when FORM::Ref1
      @ref_offset + @io.read_byte.not_nil!.to_u64
    when FORM::Ref2
      @ref_offset + @io.read_bytes(UInt16).to_u64
    when FORM::Ref4
      @ref_offset + @io.read_bytes(UInt32).to_u64
    when FORM::Ref8
      @ref_offset + @io.read_bytes(UInt64).to_u64
    when FORM::RefUdata
      @ref_offset + DWARF.read_unsigned_leb128(@io)
    when FORM::RefAddr
      read_ulong
    when FORM::RefSig8
      @io.read_bytes(UInt64)
    when FORM::String
      @io.gets('\0', chomp: true).to_s
    when FORM::Strp, FORM::LineStrp
      # HACK: A call to read_ulong is failing with an .ud2 / Illegal instruction: 4 error
      #       Calling with @[AlwaysInline] makes no difference.
      if @dwarf64
        @io.read_bytes(UInt64)
      else
        @io.read_bytes(UInt32)
      end
    when FORM::Indirect
      form = FORM.new(DWARF.read_unsigned_leb128(@io))
      read_attribute_value(form, attr)
    else
      raise "Unknown DW_FORM_#{form.to_s.underscore}"
    end
  end
end
{% end %}
{% end %}
