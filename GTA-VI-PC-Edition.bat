@echo off
setlocal
set "GTA_VI_PRESENCE_BATCH=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command "$lines = [IO.File]::ReadAllLines($env:GTA_VI_PRESENCE_BATCH); $end = [Array]::IndexOf($lines, ':worker'); & ([ScriptBlock]::Create($lines[5..($end - 1)] -join [Environment]::NewLine))"
exit /b %errorlevel%
$ErrorActionPreference = 'Stop'
$stopName = 'Local\GtaViDiscordPresence.Stop'
$publishedName = 'Local\GtaViDiscordPresence.Published'
$launchMutex = [Threading.Mutex]::new($false, 'Local\GtaViDiscordPresence.Launch')
$locked = $false
try {
    try { $locked = $launchMutex.WaitOne(15000) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another launch is still in progress.' }

    $stop = $null
    if ([Threading.EventWaitHandle]::TryOpenExisting($stopName, [ref]$stop)) {
        try { [void]$stop.Set() }
        finally { $stop.Dispose() }
        Write-Host 'Discord activity stopped.'
        exit 0
    }

    $source = $lines[($end + 1)..($lines.Length - 1)] -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source))).Replace('-', '') }
    finally { $sha.Dispose() }

    $directory = Join-Path $env:LOCALAPPDATA "GtaViDiscordPresence\$hash"
    $worker = Join-Path $directory 'GtaViPresence.exe'
    if (-not [IO.File]::Exists($worker)) {
        [void][IO.Directory]::CreateDirectory($directory)
        $staging = Join-Path $directory ('build-' + [Guid]::NewGuid().ToString('N') + '.exe')
        try {
            Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Web.Extensions.dll') -OutputType WindowsApplication -OutputAssembly $staging
            [IO.File]::Move($staging, $worker)
        }
        finally { [IO.File]::Delete($staging) }
    }

    $published = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $publishedName)
    try {
        $process = Start-Process -FilePath $worker -WindowStyle Hidden -PassThru
        try {
            if ($published.WaitOne(2500)) {
                Write-Host 'Grand Theft Auto VI / PC Edition is active.'
            } elseif ($process.HasExited) {
                throw 'The activity helper closed before connecting.'
            } else {
                Write-Host 'The helper is running. Open the Discord desktop app if needed.'
            }
        }
        finally { $process.Dispose() }
    }
    finally { $published.Dispose() }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($locked) { $launchMutex.ReleaseMutex() }
    $launchMutex.Dispose()
}
exit 0
:worker
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal static class GtaViPresence
{
    private const string Game = "Grand Theft Auto VI";
    private const string Edition = "PC Edition";
    private const string ApplicationId = "1445160676522856458";
    private const string CoverUrl = "https://images.igdb.com/igdb/image/upload/t_cover_big/cocv1v.jpg";
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    private static void Main()
    {
        bool firstInstance;
        using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset,
            @"Local\GtaViDiscordPresence.Stop", out firstInstance))
        {
            if (!firstInstance)
                return;

            using (var published = new EventWaitHandle(false, EventResetMode.ManualReset,
                @"Local\GtaViDiscordPresence.Published"))
            using (var cancel = new CancellationTokenSource())
            {
                Task activity = Task.Run(() => PublishActivity(published, cancel.Token));
                stop.WaitOne();
                cancel.Cancel();
                try { activity.GetAwaiter().GetResult(); }
                catch (OperationCanceledException) { }
            }
        }
    }

    private static async Task PublishActivity(EventWaitHandle published, CancellationToken cancel)
    {
        int pid = Process.GetCurrentProcess().Id;
        long started = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds;
        var activity = new
        {
            name = Game,
            type = 0,
            details = Edition,
            timestamps = new { start = started },
            assets = new { large_image = CoverUrl, large_text = Game },
            instance = false
        };

        while (!cancel.IsCancellationRequested)
        {
            try
            {
                using (var pipe = Connect(cancel))
                using (cancel.Register(pipe.Dispose))
                {
                    await Send(pipe, 0, Json.Serialize(new { v = 1, client_id = ApplicationId }), cancel);
                    await ReadReply(pipe, "READY", null, cancel);

                    string nonce = Guid.NewGuid().ToString();
                    await Send(pipe, 1, Json.Serialize(new
                    {
                        cmd = "SET_ACTIVITY",
                        args = new { pid, activity },
                        nonce
                    }), cancel);
                    await ReadReply(pipe, null, nonce, cancel);
                    published.Set();

                    while (!cancel.IsCancellationRequested)
                        await ReadMessage(pipe, cancel);
                }
            }
            catch (IOException) { }
            catch (TimeoutException) { }
            catch (ObjectDisposedException) { }
            catch (OperationCanceledException) { }
            finally { published.Reset(); }

            await Task.Delay(4000, cancel);
        }
    }

    private static NamedPipeClientStream Connect(CancellationToken cancel)
    {
        for (int index = 0; index < 10; index++)
        {
            cancel.ThrowIfCancellationRequested();
            var pipe = new NamedPipeClientStream(".", "discord-ipc-" + index, PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                pipe.Connect(130);
                return pipe;
            }
            catch (TimeoutException) { pipe.Dispose(); }
            catch { pipe.Dispose(); throw; }
        }

        throw new TimeoutException();
    }

    private static async Task ReadReply(NamedPipeClientStream pipe, string expectedEvent, string expectedNonce, CancellationToken cancel)
    {
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel))
        {
            deadline.CancelAfter(10000);
            using (deadline.Token.Register(pipe.Dispose))
            {
                while (true)
                {
                    var message = await ReadMessage(pipe, deadline.Token);
                    if (message == null)
                        continue;

                    object eventName;
                    object nonce;
                    message.TryGetValue("evt", out eventName);
                    message.TryGetValue("nonce", out nonce);
                    if (Equals(eventName, "ERROR"))
                        throw new IOException("Discord rejected the activity.");
                    if ((expectedEvent != null && Equals(eventName, expectedEvent)) ||
                        (expectedNonce != null && Equals(nonce, expectedNonce)))
                        return;
                }
            }
        }
    }

    private static async Task<Dictionary<string, object>> ReadMessage(NamedPipeClientStream pipe, CancellationToken cancel)
    {
        var header = new byte[8];
        await ReadAll(pipe, header, cancel);
        int opcode = BitConverter.ToInt32(header, 0);
        int length = BitConverter.ToInt32(header, 4);
        if (length < 0 || length > 1024 * 1024)
            throw new IOException("Invalid Discord IPC frame size.");

        var payload = new byte[length];
        await ReadAll(pipe, payload, cancel);
        string body = Encoding.UTF8.GetString(payload);
        switch (opcode)
        {
            case 1:
                return Json.Deserialize<Dictionary<string, object>>(body);
            case 2:
                throw new IOException("Discord closed the connection.");
            case 3:
                await Send(pipe, 4, body, cancel);
                break;
        }
        return null;
    }

    private static async Task ReadAll(Stream stream, byte[] bytes, CancellationToken cancel)
    {
        int offset = 0;
        while (offset < bytes.Length)
        {
            int count = await stream.ReadAsync(bytes, offset, bytes.Length - offset, cancel);
            if (count == 0)
                throw new EndOfStreamException();
            offset += count;
        }
    }

    private static Task Send(Stream stream, int opcode, string body, CancellationToken cancel)
    {
        byte[] payload = Encoding.UTF8.GetBytes(body);
        var frame = new byte[8 + payload.Length];
        Buffer.BlockCopy(BitConverter.GetBytes(opcode), 0, frame, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(payload.Length), 0, frame, 4, 4);
        Buffer.BlockCopy(payload, 0, frame, 8, payload.Length);
        return stream.WriteAsync(frame, 0, frame.Length, cancel);
    }
}
