using System.Diagnostics;

namespace Cage.Windows;

// Own only the handles started here. Closing admission and starting a helper
// share one lock; a close can never miss an admitted but not-yet-started child.
internal sealed class NativeHelperLifetime
{
    private readonly object gate = new();
    private readonly CancellationTokenSource stopping = new();
    private TaskCompletionSource idle = CompletedSignal();
    private bool closed;
    private int active;
    private Exception? cleanupFailure;
    internal static readonly TimeSpan CleanupDeadline = TimeSpan.FromSeconds(5);

    internal int ActiveCount { get { lock (gate) return active; } }
    internal CancellationToken Stopping => stopping.Token;

    internal Helper Start(ProcessStartInfo start, bool shutdown = false)
    {
        lock (gate)
        {
            if (shutdown ? !closed || active != 0 || cleanupFailure != null : closed)
                throw new InvalidOperationException("自检正在关闭，不能启动新的后台请求");
            var process = new Process { StartInfo = start };
            try
            {
                if (!process.Start()) throw new IOException("无法启动 Cage 后台");
            }
            catch { process.Dispose(); throw; }
            if (active++ == 0) idle = new(TaskCreationOptions.RunContinuationsAsynchronously);
            return new Helper(this, process);
        }
    }

    internal void CloseAdmission() { lock (gate) closed = true; }

    // Give already-started commands a grace period to publish their controller
    // records. If needed, cancel them, then still wait for owned-handle cleanup.
    internal async Task<bool> DrainAsync(TimeSpan grace)
    {
        Task pending;
        lock (gate) { closed = true; pending = idle.Task; }
        var graceful = true;
        try { await pending.WaitAsync(grace).ConfigureAwait(false); }
        catch (TimeoutException)
        {
            graceful = false;
            stopping.Cancel();
            await pending.WaitAsync(CleanupDeadline + TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        }
        lock (gate)
            if (cleanupFailure != null) throw new IOException("自检辅助进程尚未确认退出", cleanupFailure);
        return graceful;
    }

    private void Finish(Exception? error)
    {
        lock (gate)
        {
            cleanupFailure ??= error;
            if (--active == 0) idle.TrySetResult();
        }
    }

    private static TaskCompletionSource CompletedSignal()
    {
        var signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        signal.SetResult(); return signal;
    }

    internal static Task WaitForProcessExitAsync(Process process, CancellationToken token) => Task.Run(() => {
        // A synchronous wait disposes its kernel wait handle before return.
        // Run it off the UI thread and use bounded waits for cancellation;
        // no Exited callback/registered wait can outlive this barrier. This is
        // wait-only, including for identity-checked smoke controller handles.
        while (!process.WaitForExit(100)) token.ThrowIfCancellationRequested();
        token.ThrowIfCancellationRequested();
    });

    internal sealed class Helper(NativeHelperLifetime owner, Process process)
    {
        internal Process Process => process;
        internal Task WaitForExitAsync(CancellationToken token) => WaitForProcessExitAsync(process, token);
        internal async Task CompleteAsync(Task[] io, params IDisposable?[] streams)
        {
            var elapsed = Stopwatch.StartNew();
            Exception? failure = null;
            try
            {
                // No name/PID lookup and no process-tree kill: only this handle.
                try { if (!process.HasExited) process.Kill(); }
                catch (InvalidOperationException) when (process.HasExited) { }
                if (!await Task.Run(() => process.WaitForExit((int)CleanupDeadline.TotalMilliseconds)).ConfigureAwait(false))
                    throw new TimeoutException("自检辅助进程退出超时");
                // Accessing Process.Standard* gives the caller ownership of the
                // streams. Process.Dispose alone does not close these handles.
                foreach (var stream in streams) DisposeStream(stream);
                var remaining = CleanupDeadline - elapsed.Elapsed;
                try { await Task.WhenAll(io).WaitAsync(remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero).ConfigureAwait(false); }
                catch (TimeoutException) when (io.Any(task => !task.IsCompleted)) { throw; }
                catch (Exception) { /* Preserve the original pipe/operation failure. */ }
            }
            catch (Exception error) { failure = error; throw; }
            finally
            {
                try { foreach (var stream in streams) DisposeStream(stream); }
                finally { process.Dispose(); owner.Finish(failure); }
            }
        }

        private static void DisposeStream(IDisposable? stream)
        {
            if (stream is StreamWriter writer)
            {
                // After cancellation/kill, flushing a buffered stdin writer can
                // fail or race a cancelled write. Release its actual pipe first.
                writer.BaseStream.Dispose();
                try { writer.Dispose(); }
                catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException) { }
            }
            else stream?.Dispose();
        }
    }
}
