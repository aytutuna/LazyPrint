using System.Windows.Threading;

namespace LazyPrint.App.Services;

/// <summary>Runs drawing and print-system work on a thread of its own in the single-threaded apartment.</summary>
internal static class StaWork
{
    public static Task<T> Run<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { done.SetResult(work()); }
            catch (Exception e) { done.SetException(e); }
        })
        {
            IsBackground = true,
            Name = "Lazy Print render",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }

    /// <summary>
    /// Runs async work on a thread of its own in the single-threaded apartment, with a dispatcher running: the XPS writer
    /// reports back through it.
    /// </summary>
    public static Task RunAsync(Func<Task> work)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                try
                {
                    await work();
                    done.TrySetResult();
                }
                catch (OperationCanceledException e)
                {
                    done.TrySetCanceled(e.CancellationToken);
                }
                catch (Exception e)
                {
                    done.TrySetException(e);
                }
                finally
                {
                    dispatcher.BeginInvokeShutdown(DispatcherPriority.Background);
                }
            });
            Dispatcher.Run();
        })
        {
            IsBackground = true,
            Name = "Lazy Print render",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }
}
