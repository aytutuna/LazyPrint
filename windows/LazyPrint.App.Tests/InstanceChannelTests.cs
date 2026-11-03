using System.Collections.Concurrent;
using System.Text;
using LazyPrint.App.Services;
using Xunit;

namespace LazyPrint.App.Tests;

// The message a second start of the app sends the first: a JSON array of paths over the pipe LazyPrint.Open.
public sealed class InstanceChannelTests
{
    private static string UniquePipe() => "LazyPrint.Open.test-" + Guid.NewGuid().ToString("N");

    [Fact]
    public void PathsGoAsAJsonArrayOfStrings()
    {
        byte[] message = InstanceChannel.Encode([@"C:\Docs\a.pdf", @"C:\Docs\b.jpg"]);

        Assert.Equal("""["C:\\Docs\\a.pdf","C:\\Docs\\b.jpg"]""", Encoding.UTF8.GetString(message));
    }

    [Fact]
    public void PathsComeBackAsTheyWentIncludingQuotesAndLetters()
    {
        string[] paths = ["C:\\Docs\\M\u00fcller \"final\".pdf", "\\\\server\\share\\\u65e5\u672c\u8a9e.png"];

        Assert.Equal(paths, InstanceChannel.Decode(InstanceChannel.Encode(paths)));
    }

    [Fact]
    public void NoPathsIsAnEmptyListNotAnError()
    {
        Assert.Empty(InstanceChannel.Decode(InstanceChannel.Encode([]))!);
        Assert.Empty(InstanceChannel.Decode("[]"u8)!);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("""{"files":["a.pdf"]}""")]
    [InlineData("[1,2]")]
    public void AnythingElseIsNotAMessage(string text)
    {
        Assert.Null(InstanceChannel.Decode(Encoding.UTF8.GetBytes(text)));
    }

    [Fact]
    public void BlankEntriesAreDropped()
    {
        Assert.Equal(["a.pdf"], InstanceChannel.Decode("""["", " ", "a.pdf"]"""u8));
    }

    [Fact]
    public async Task AMessageSentToTheFirstInstanceArrivesThere()
    {
        string pipe = UniquePipe();
        var received = new TaskCompletionSource<IReadOnlyList<string>>();
        using var channel = new InstanceChannel(paths => received.TrySetResult(paths), pipe);

        Assert.True(InstanceChannel.Send([@"C:\a.pdf", @"C:\b.pdf"], pipe));

        Assert.Equal([@"C:\a.pdf", @"C:\b.pdf"], await received.Task.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task TheFirstInstanceKeepsListeningAfterAMessage()
    {
        string pipe = UniquePipe();
        var received = new BlockingCollection<IReadOnlyList<string>>();
        using var channel = new InstanceChannel(paths => received.Add(paths), pipe);

        Assert.True(InstanceChannel.Send(["one.pdf"], pipe));
        Assert.True(InstanceChannel.Send([], pipe));

        Assert.Equal(["one.pdf"], await Task.Run(() => received.Take()).WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Empty(await Task.Run(() => received.Take()).WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void SendingWithNoFirstInstanceFails()
    {
        Assert.False(InstanceChannel.Send(["a.pdf"], UniquePipe(), timeout: 100));
    }
}
