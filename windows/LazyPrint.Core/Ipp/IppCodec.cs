using System.Text;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppCodec.swift: IPP messages as bytes (RFC 8010).

/// <summary>An IPP version. 2.0 is sent; 1.x and 2.x are read.</summary>
public readonly record struct IppVersion(byte Major, byte Minor)
{
    public static readonly IppVersion V20 = new(2, 0);
    public static readonly IppVersion V11 = new(1, 1);

    public override string ToString() => $"{Major}.{Minor}";
}

/// <summary>Group delimiter and value tags (RFC 8010 §3.5.1, §3.5.2).</summary>
public static class IppTag
{
    public const byte OperationAttributes = 0x01;
    public const byte JobAttributes = 0x02;
    public const byte EndOfAttributes = 0x03;
    public const byte PrinterAttributes = 0x04;
    public const byte UnsupportedAttributes = 0x05;

    public const byte Unsupported = 0x10;
    public const byte Unknown = 0x12;
    public const byte NoValue = 0x13;
    public const byte Integer = 0x21;
    public const byte Boolean = 0x22;
    public const byte Enum = 0x23;
    public const byte OctetString = 0x30;
    public const byte DateTime = 0x31;
    public const byte Resolution = 0x32;
    public const byte RangeOfInteger = 0x33;
    public const byte BegCollection = 0x34;
    public const byte TextWithLanguage = 0x35;
    public const byte NameWithLanguage = 0x36;
    public const byte EndCollection = 0x37;
    public const byte Text = 0x41;
    public const byte Name = 0x42;
    public const byte Keyword = 0x44;
    public const byte Uri = 0x45;
    public const byte UriScheme = 0x46;
    public const byte Charset = 0x47;
    public const byte NaturalLanguage = 0x48;
    public const byte MimeMediaType = 0x49;
    public const byte MemberAttrName = 0x4A;
}

/// <summary>One value of an attribute.</summary>
public abstract record IppValue
{
    private IppValue() { }

    public sealed record Integer(int Value) : IppValue;
    public sealed record Bool(bool Value) : IppValue;
    public sealed record EnumValue(int Value) : IppValue;
    public sealed record Octets(byte[] Value) : IppValue
    {
        public bool Equals(Octets? other) => other is not null && Value.AsSpan().SequenceEqual(other.Value);
        public override int GetHashCode() => Value.Length;
    }
    /// <summary>The 11 bytes of RFC 2579 DateAndTime, as they came.</summary>
    public sealed record DateTimeValue(byte[] Value) : IppValue
    {
        public bool Equals(DateTimeValue? other) => other is not null && Value.AsSpan().SequenceEqual(other.Value);
        public override int GetHashCode() => Value.Length;
    }
    /// <summary>Units 3 are dots per inch, 4 dots per centimetre.</summary>
    public sealed record Resolution(int X, int Y, byte Units) : IppValue;
    public sealed record Range(int Lower, int Upper) : IppValue;
    public sealed record Text(string Value) : IppValue;
    public sealed record Name(string Value) : IppValue;
    public sealed record Keyword(string Value) : IppValue;
    public sealed record Uri(string Value) : IppValue;
    public sealed record UriScheme(string Value) : IppValue;
    public sealed record Charset(string Value) : IppValue;
    public sealed record Language(string Value) : IppValue;
    public sealed record MimeType(string Value) : IppValue;
    public sealed record Collection(IReadOnlyList<IppAttribute> Members) : IppValue
    {
        public bool Equals(Collection? other) => other is not null && Members.SequenceEqual(other.Members);
        public override int GetHashCode() => Members.Count;
    }
    /// <summary>0x10 unsupported, 0x12 unknown, 0x13 no-value.</summary>
    public sealed record OutOfBand(byte Tag) : IppValue;
    /// <summary>A value tag this codec does not know, or a known one with a length it should not have, kept as it came.</summary>
    public sealed record Unknown(byte Tag, byte[] Value) : IppValue
    {
        public bool Equals(Unknown? other) => other is not null && Tag == other.Tag && Value.AsSpan().SequenceEqual(other.Value);
        public override int GetHashCode() => HashCode.Combine(Tag, Value.Length);
    }
}

/// <summary>A named attribute with one or more values.</summary>
public sealed record IppAttribute(string Name, IReadOnlyList<IppValue> Values)
{
    public IppAttribute(string name, params IppValue[] values) : this(name, (IReadOnlyList<IppValue>)values) { }

    public bool Equals(IppAttribute? other) =>
        other is not null && Name == other.Name && Values.SequenceEqual(other.Values);

    public override int GetHashCode() => HashCode.Combine(Name, Values.Count);
}

/// <summary>The attributes after one delimiter tag: 0x01 operation, 0x02 job, 0x04 printer, 0x05 unsupported, any 0x00-0x0F kept.</summary>
public sealed record IppGroup(byte Tag, IReadOnlyList<IppAttribute> Attributes)
{
    public bool Equals(IppGroup? other) =>
        other is not null && Tag == other.Tag && Attributes.SequenceEqual(other.Attributes);

    public override int GetHashCode() => HashCode.Combine(Tag, Attributes.Count);
}

public enum IppOperation : ushort
{
    PrintJob = 0x0002,
    ValidateJob = 0x0004,
    CancelJob = 0x0008,
    GetJobAttributes = 0x0009,
    GetJobs = 0x000A,
    GetPrinterAttributes = 0x000B,
}

/// <summary>A request or a response; <see cref="Code"/> is the operation id in a request, the status code in a response.</summary>
public sealed record IppMessage(IppVersion Version, ushort Code, int RequestId, IReadOnlyList<IppGroup> Groups)
{
    public bool Equals(IppMessage? other) =>
        other is not null && Version == other.Version && Code == other.Code && RequestId == other.RequestId
        && Groups.SequenceEqual(other.Groups);

    public override int GetHashCode() => HashCode.Combine(Version, Code, RequestId, Groups.Count);

    /// <summary>Successful-ok and the two other successes (codes below 0x0100).</summary>
    public bool IsSuccess => Code < 0x0100;

    /// <summary>The first attribute of that name outside the unsupported-attributes group.</summary>
    public IppAttribute? this[string name]
    {
        get
        {
            foreach (IppGroup group in Groups)
            {
                if (group.Tag == IppTag.UnsupportedAttributes) continue;
                foreach (IppAttribute attribute in group.Attributes)
                    if (attribute.Name == name) return attribute;
            }
            return null;
        }
    }

    public byte[] Encoded()
    {
        var output = new MemoryStream();
        output.WriteByte(Version.Major);
        output.WriteByte(Version.Minor);
        WriteUInt16(output, Code);
        WriteInt32(output, RequestId);
        foreach (IppGroup group in Groups)
        {
            output.WriteByte(group.Tag);
            foreach (IppAttribute attribute in group.Attributes)
            {
                for (int i = 0; i < attribute.Values.Count; i++)
                    WriteValue(output, attribute.Values[i], i == 0 ? attribute.Name : "");
            }
        }
        output.WriteByte(IppTag.EndOfAttributes);
        return output.ToArray();
    }

    /// <summary>
    /// Reads a message from the start of <paramref name="data"/>. A document, if there is one, starts at
    /// <c>DocumentOffset</c>. Throws a <see cref="PrintException"/> (bad response) for data that is cut short or not IPP.
    /// </summary>
    public static (IppMessage Message, int DocumentOffset) Decode(ReadOnlySpan<byte> data)
    {
        try
        {
            var reader = new Reader(data);
            byte major = reader.Byte();
            byte minor = reader.Byte();
            if (major is not (1 or 2)) throw Bad();
            ushort code = reader.UInt16();
            int requestId = reader.Int32();
            var groups = new List<IppGroup>();
            byte tag = reader.Byte();
            while (tag != IppTag.EndOfAttributes)
            {
                if (tag > 0x0F) throw Bad();
                byte groupTag = tag;
                var attributes = new List<(string Name, List<IppValue> Values)>();
                tag = reader.Byte();
                while (tag > 0x0F)
                {
                    string name = reader.Text(reader.UInt16());
                    IppValue value = ReadValue(ref reader, tag, 0);
                    if (name.Length > 0) attributes.Add((name, [value]));
                    else if (attributes.Count > 0) attributes[^1].Values.Add(value);
                    else throw Bad();
                    tag = reader.Byte();
                }
                groups.Add(new IppGroup(groupTag, [.. attributes.Select(a => new IppAttribute(a.Name, a.Values))]));
            }
            return (new IppMessage(new IppVersion(major, minor), code, requestId, groups), reader.Position);
        }
        catch (IndexOutOfRangeException)
        {
            throw Bad();
        }
    }

    private static PrintException Bad() => new(new PrintError.BadResponse());

    // Real printers nest two or three deep; a reply deeper than this is hostile and would overflow the stack.
    private const int MaxDepth = 16;

    private static IppValue ReadValue(ref Reader reader, byte tag, int depth)
    {
        int length = reader.UInt16();
        if (tag == IppTag.BegCollection)
        {
            if (depth >= MaxDepth) throw Bad();
            reader.Skip(length);
            return ReadCollection(ref reader, depth + 1);
        }
        return Value(tag, reader.Bytes(length));
    }

    // Members come as a memberAttrName whose value is the name, then that member's values with empty names.
    private static IppValue.Collection ReadCollection(ref Reader reader, int depth)
    {
        var members = new List<(string Name, List<IppValue> Values)>();
        while (true)
        {
            byte tag = reader.Byte();
            reader.Skip(reader.UInt16());
            if (tag == IppTag.EndCollection)
            {
                reader.Skip(reader.UInt16());
                break;
            }
            if (tag == IppTag.MemberAttrName)
            {
                members.Add((reader.Text(reader.UInt16()), []));
                continue;
            }
            if (members.Count == 0) throw Bad();
            members[^1].Values.Add(ReadValue(ref reader, tag, depth));
        }
        return new IppValue.Collection([.. members.Select(m => new IppAttribute(m.Name, m.Values))]);
    }

    private static IppValue Value(byte tag, byte[] bytes)
    {
        switch (tag)
        {
            case IppTag.Integer when bytes.Length == 4: return new IppValue.Integer(Int32(bytes, 0));
            case IppTag.Enum when bytes.Length == 4: return new IppValue.EnumValue(Int32(bytes, 0));
            case IppTag.Boolean when bytes.Length == 1: return new IppValue.Bool(bytes[0] != 0);
            case IppTag.OctetString: return new IppValue.Octets(bytes);
            case IppTag.DateTime when bytes.Length == 11: return new IppValue.DateTimeValue(bytes);
            case IppTag.Resolution when bytes.Length == 9: return new IppValue.Resolution(Int32(bytes, 0), Int32(bytes, 4), bytes[8]);
            case IppTag.RangeOfInteger when bytes.Length == 8: return new IppValue.Range(Int32(bytes, 0), Int32(bytes, 4));
            case IppTag.Unsupported or IppTag.Unknown or IppTag.NoValue when bytes.Length == 0: return new IppValue.OutOfBand(tag);
            case IppTag.Text: return new IppValue.Text(Utf8(bytes));
            case IppTag.Name: return new IppValue.Name(Utf8(bytes));
            case IppTag.Keyword: return new IppValue.Keyword(Utf8(bytes));
            case IppTag.Uri: return new IppValue.Uri(Utf8(bytes));
            case IppTag.UriScheme: return new IppValue.UriScheme(Utf8(bytes));
            case IppTag.Charset: return new IppValue.Charset(Utf8(bytes));
            case IppTag.NaturalLanguage: return new IppValue.Language(Utf8(bytes));
            case IppTag.MimeMediaType: return new IppValue.MimeType(Utf8(bytes));
            case IppTag.TextWithLanguage or IppTag.NameWithLanguage:
                string? text = WithLanguage(bytes);
                if (text is null) break;
                return tag == IppTag.TextWithLanguage ? new IppValue.Text(text) : new IppValue.Name(text);
        }
        return new IppValue.Unknown(tag, bytes);
    }

    // Two length-prefixed strings, the language and the text; only the text is kept.
    private static string? WithLanguage(byte[] bytes)
    {
        if (bytes.Length < 4) return null;
        int language = (bytes[0] << 8) | bytes[1];
        if (bytes.Length < 2 + language + 2) return null;
        int offset = 2 + language;
        int length = (bytes[offset] << 8) | bytes[offset + 1];
        if (bytes.Length < offset + 2 + length) return null;
        return Encoding.UTF8.GetString(bytes, offset + 2, length);
    }

    private static string Utf8(byte[] bytes) => Encoding.UTF8.GetString(bytes);

    private static int Int32(byte[] bytes, int offset) =>
        (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];

    private static void WriteUInt16(Stream output, int value)
    {
        output.WriteByte((byte)(value >> 8));
        output.WriteByte((byte)value);
    }

    private static void WriteInt32(Stream output, int value)
    {
        WriteUInt16(output, value >> 16);
        WriteUInt16(output, value);
    }

    private static void WriteEntry(Stream output, byte tag, string name, ReadOnlySpan<byte> value)
    {
        output.WriteByte(tag);
        byte[] nameBytes = Encoding.UTF8.GetBytes(name);
        WriteUInt16(output, nameBytes.Length);
        output.Write(nameBytes);
        WriteUInt16(output, value.Length);
        output.Write(value);
    }

    private static void WriteText(Stream output, byte tag, string name, string text) =>
        WriteEntry(output, tag, name, Encoding.UTF8.GetBytes(text));

    private static byte[] Int32Bytes(params int[] values)
    {
        var stream = new MemoryStream();
        foreach (int value in values) WriteInt32(stream, value);
        return stream.ToArray();
    }

    private static void WriteValue(Stream output, IppValue value, string name)
    {
        switch (value)
        {
            case IppValue.Integer v: WriteEntry(output, IppTag.Integer, name, Int32Bytes(v.Value)); break;
            case IppValue.Bool v: WriteEntry(output, IppTag.Boolean, name, [(byte)(v.Value ? 1 : 0)]); break;
            case IppValue.EnumValue v: WriteEntry(output, IppTag.Enum, name, Int32Bytes(v.Value)); break;
            case IppValue.Octets v: WriteEntry(output, IppTag.OctetString, name, v.Value); break;
            case IppValue.DateTimeValue v: WriteEntry(output, IppTag.DateTime, name, v.Value); break;
            case IppValue.Resolution v:
                WriteEntry(output, IppTag.Resolution, name, [.. Int32Bytes(v.X, v.Y), v.Units]);
                break;
            case IppValue.Range v: WriteEntry(output, IppTag.RangeOfInteger, name, Int32Bytes(v.Lower, v.Upper)); break;
            case IppValue.Text v: WriteText(output, IppTag.Text, name, v.Value); break;
            case IppValue.Name v: WriteText(output, IppTag.Name, name, v.Value); break;
            case IppValue.Keyword v: WriteText(output, IppTag.Keyword, name, v.Value); break;
            case IppValue.Uri v: WriteText(output, IppTag.Uri, name, v.Value); break;
            case IppValue.UriScheme v: WriteText(output, IppTag.UriScheme, name, v.Value); break;
            case IppValue.Charset v: WriteText(output, IppTag.Charset, name, v.Value); break;
            case IppValue.Language v: WriteText(output, IppTag.NaturalLanguage, name, v.Value); break;
            case IppValue.MimeType v: WriteText(output, IppTag.MimeMediaType, name, v.Value); break;
            case IppValue.OutOfBand v: WriteEntry(output, v.Tag, name, []); break;
            case IppValue.Unknown v: WriteEntry(output, v.Tag, name, v.Value); break;
            case IppValue.Collection v:
                WriteEntry(output, IppTag.BegCollection, name, []);
                foreach (IppAttribute member in v.Members)
                {
                    WriteText(output, IppTag.MemberAttrName, "", member.Name);
                    foreach (IppValue memberValue in member.Values) WriteValue(output, memberValue, "");
                }
                WriteEntry(output, IppTag.EndCollection, "", []);
                break;
        }
    }

    // A read past the end throws IndexOutOfRangeException, which Decode turns into a bad response.
    private ref struct Reader(ReadOnlySpan<byte> data)
    {
        private readonly ReadOnlySpan<byte> data = data;

        public int Position { get; private set; }

        public byte Byte() => data[Position++];

        public ushort UInt16() => (ushort)((Byte() << 8) | Byte());

        public int Int32() => (Byte() << 24) | (Byte() << 16) | (Byte() << 8) | Byte();

        public void Skip(int count)
        {
            if (count > data.Length - Position) throw new IndexOutOfRangeException();
            Position += count;
        }

        public byte[] Bytes(int count)
        {
            if (count > data.Length - Position) throw new IndexOutOfRangeException();
            byte[] bytes = data.Slice(Position, count).ToArray();
            Position += count;
            return bytes;
        }

        public string Text(int count) => Encoding.UTF8.GetString(Bytes(count));
    }
}
