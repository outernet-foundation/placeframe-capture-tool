using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

namespace Placeframe.Client
{
    public enum UploadPhase
    {
        Draining,
        Sending,
    }

    public readonly struct UploadProgress
    {
        public readonly UploadPhase Phase;
        public readonly float? Percent;
        public readonly long BytesSent;
        public readonly long? BytesTotal;
        public readonly double? BytesPerSecond;

        public UploadProgress(UploadPhase phase, float? percent, long bytesSent, long? bytesTotal, double? bytesPerSecond)
        {
            Phase = phase;
            Percent = percent;
            BytesSent = bytesSent;
            BytesTotal = bytesTotal;
            BytesPerSecond = bytesPerSecond;
        }
    }

    // Attach one upload's progress to every request that flows through
    public sealed class UploadProgressHandler : DelegatingHandler
    {
        private readonly IProgress<UploadProgress> _progress;

        public UploadProgressHandler(IProgress<UploadProgress> progress)
        {
            _progress = progress;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken
        )
        {
            request.Properties[ProgressReportingHttpHandler.ProgressProperty] = _progress;
            return base.SendAsync(request, cancellationToken);
        }
    }

    // Report throttled ticks with a one second moving average speed
    internal sealed class UploadProgressTicker
    {
        private static readonly TimeSpan ReportInterval = TimeSpan.FromMilliseconds(200);
        private static readonly TimeSpan SpeedWindow = TimeSpan.FromSeconds(1);

        private readonly IProgress<UploadProgress> _progress;
        private readonly long? _total;
        private readonly UploadPhase _phase;
        private readonly Queue<(DateTime time, long bytes)> _speedSamples = new Queue<(DateTime, long)>();
        private long _bytes;
        private DateTime _lastReport = DateTime.MinValue;
        private double? _lastBytesPerSecond;

        public UploadProgressTicker(IProgress<UploadProgress> progress, long? total, UploadPhase phase)
        {
            _progress = progress;
            _total = total;
            _phase = phase;
        }

        public double? LastBytesPerSecond => _lastBytesPerSecond;

        public void Add(long count)
        {
            _bytes += count;
            var now = DateTime.UtcNow;
            if (now - _lastReport < ReportInterval) return;
            _lastReport = now;

            _speedSamples.Enqueue((now, _bytes));
            while (_speedSamples.Count > 1 && now - _speedSamples.Peek().time > SpeedWindow)
                _speedSamples.Dequeue();

            var oldest = _speedSamples.Peek();
            var elapsed = (now - oldest.time).TotalSeconds;
            _lastBytesPerSecond = elapsed > 0 ? (_bytes - oldest.bytes) / elapsed : (double?)null;

            _progress.Report(new UploadProgress(
                _phase,
                percent: _total.HasValue && _total.Value > 0 ? (float?)(_bytes * 100.0 / _total.Value) : null,
                bytesSent: _bytes,
                bytesTotal: _total,
                bytesPerSecond: _lastBytesPerSecond));
        }
    }

    // Fill the send buffer while progress ticks on every chunk that crosses
    internal sealed class DrainingBuffer : Stream
    {
        private readonly byte[] _buffer;
        private readonly MemoryStream _fallback;
        private readonly UploadProgressTicker _ticker;
        private int _filled;

        public DrainingBuffer(long? total, UploadProgressTicker ticker)
        {
            _buffer = total.HasValue && total.Value > 0 && total.Value <= int.MaxValue
                ? new byte[total.Value]
                : null;
            _fallback = _buffer == null ? new MemoryStream() : null;
            _ticker = ticker;
        }

        public byte[] ToArray() => _buffer ?? _fallback.ToArray();

        public void VerifyComplete()
        {
            if (_buffer != null && _filled != _buffer.Length)
                throw new IOException("Upload body ended before Content-Length");
        }

        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count)
        {
            if (_buffer != null)
            {
                if (_filled + count > _buffer.Length)
                    throw new IOException("Upload body longer than Content-Length");
                Buffer.BlockCopy(buffer, offset, _buffer, _filled, count);
                _filled += count;
            }
            else
            {
                _fallback.Write(buffer, offset, count);
            }
            _ticker.Add(count);
        }
    }

    // Send bodies unbuffered so reported progress counts bytes that left the process
    public sealed class ProgressReportingHttpHandler : HttpMessageHandler
    {
        internal const string ProgressProperty = "Placeframe.UploadProgress";

        private const int CopyChunkBytes = 64 * 1024;

        private static readonly HashSet<string> ResponseContentHeaderNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Allow", "Content-Disposition", "Content-Encoding", "Content-Language",
            "Content-Length", "Content-Location", "Content-MD5", "Content-Range",
            "Content-Type", "Expires", "Last-Modified"
        };

        static ProgressReportingHttpHandler()
        {
            ServicePointManager.Expect100Continue = false;
            ServicePointManager.DefaultConnectionLimit = 16;
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken
        )
        {
            var progress = request.Properties.TryGetValue(ProgressProperty, out var value)
                && value is IProgress<UploadProgress> typed
                ? typed
                : null;
            HttpContent content = request.Content;
            if (progress != null && content != null)
                content = await BufferForProgressAsync(content, progress, cancellationToken).ConfigureAwait(false);

            var webRequest = CreateWebRequest(request, content);
            using (cancellationToken.Register(() => webRequest.Abort()))
            {
                if (content != null)
                    await WriteBodyAsync(webRequest, content, progress).ConfigureAwait(false);

                try
                {
                    var webResponse = (HttpWebResponse)await webRequest.GetResponseAsync().ConfigureAwait(false);
                    return BuildResponse(webResponse);
                }
                catch (WebException exception) when (exception.Status == WebExceptionStatus.RequestCanceled)
                {
                    throw new OperationCanceledException(cancellationToken);
                }
                catch (WebException exception) when (exception.Response is HttpWebResponse errorResponse)
                {
                    return BuildResponse(errorResponse);
                }
                catch (WebException exception)
                {
                    throw new HttpRequestException(exception.Message, exception);
                }
            }
        }

        // Buffer the body before send so the wire write is one known-length copy
        private static async Task<HttpContent> BufferForProgressAsync(
            HttpContent content,
            IProgress<UploadProgress> progress,
            CancellationToken cancellationToken
        )
        {
            var total = content.Headers.ContentLength;
            var ticker = new UploadProgressTicker(progress, total, UploadPhase.Draining);
            using var drain = new DrainingBuffer(total, ticker);
            await content.CopyToAsync(drain).ConfigureAwait(false);
            drain.VerifyComplete();

            var buffered = new ByteArrayContent(drain.ToArray());
            foreach (var header in content.Headers)
                buffered.Headers.TryAddWithoutValidation(header.Key, header.Value);
            content.Dispose();

            progress.Report(new UploadProgress(
                UploadPhase.Sending,
                percent: total.HasValue && total.Value > 0 ? 0f : (float?)null,
                bytesSent: 0,
                bytesTotal: total,
                bytesPerSecond: null));
            return buffered;
        }

        private static HttpWebRequest CreateWebRequest(HttpRequestMessage request, HttpContent content)
        {
            var webRequest = (HttpWebRequest)WebRequest.Create(request.RequestUri);
            webRequest.Method = request.Method.Method;
            webRequest.AllowWriteStreamBuffering = false;
            webRequest.AllowAutoRedirect = true;
            // Leave per-request timeouts infinite because HttpClient.Timeout governs end to end
            webRequest.Timeout = Timeout.Infinite;
            webRequest.ReadWriteTimeout = Timeout.Infinite;

            foreach (var header in request.Headers)
            {
                // Route restricted headers through their dedicated HttpWebRequest properties
                if (header.Key == "Accept")
                {
                    webRequest.Accept = string.Join(", ", header.Value);
                    continue;
                }
                if (header.Key == "Referer")
                {
                    webRequest.Referer = string.Join(", ", header.Value);
                    continue;
                }
                if (header.Key == "User-Agent")
                {
                    webRequest.UserAgent = string.Join(", ", header.Value);
                    continue;
                }
                // Drop headers the transport owns
                if (header.Key == "Host" || header.Key == "Expect" || header.Key == "Connection" || header.Key == "Transfer-Encoding")
                    continue;

                foreach (var value in header.Value)
                    webRequest.Headers.Add(header.Key, value);
            }

            if (content != null)
            {
                foreach (var header in content.Headers)
                {
                    if (header.Key == "Content-Type")
                        webRequest.ContentType = string.Join(", ", header.Value);
                    else if (header.Key != "Content-Length")
                        foreach (var value in header.Value)
                            webRequest.Headers.Add(header.Key, value);
                }
            }

            return webRequest;
        }

        private static async Task WriteBodyAsync(
            HttpWebRequest webRequest,
            HttpContent content,
            IProgress<UploadProgress> progress
        )
        {
            // Pin Content-Length or SendChunked so Mono hands out an unbuffered stream
            var length = content.Headers.ContentLength;
            if (length.HasValue)
                webRequest.ContentLength = length.Value;
            else
                webRequest.SendChunked = true;

            using var requestStream = await webRequest.GetRequestStreamAsync().ConfigureAwait(false);

            if (progress == null)
            {
                await content.CopyToAsync(requestStream).ConfigureAwait(false);
                return;
            }

            // Write in chunks so progress ticks while the stream blocks on the socket
            using var progressStream = new ProgressReportingStream(requestStream, progress, length);
            var buffer = new byte[CopyChunkBytes];
            using var source = await content.ReadAsStreamAsync().ConfigureAwait(false);
            while (true)
            {
                int read = await source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (read == 0)
                    break;
                await progressStream.WriteAsync(buffer, 0, read).ConfigureAwait(false);
            }

            if (length.HasValue && length.Value > 0)
                progress.Report(new UploadProgress(
                    UploadPhase.Sending,
                    percent: 100f,
                    bytesSent: length.Value,
                    bytesTotal: length,
                    bytesPerSecond: progressStream.LastBytesPerSecond));
        }

        private static HttpResponseMessage BuildResponse(HttpWebResponse webResponse)
        {
            var response = new HttpResponseMessage(webResponse.StatusCode)
            {
                ReasonPhrase = webResponse.StatusDescription,
                Content = new StreamContent(webResponse.GetResponseStream())
            };

            foreach (var key in webResponse.Headers.AllKeys)
            {
                var target = ResponseContentHeaderNames.Contains(key)
                    ? (HttpHeaders)response.Content.Headers
                    : response.Headers;
                target.TryAddWithoutValidation(key, webResponse.Headers.GetValues(key));
            }

            return response;
        }
    }

    internal sealed class ProgressReportingStream : Stream
    {
        private readonly Stream _inner;
        private readonly UploadProgressTicker _ticker;

        public ProgressReportingStream(Stream inner, IProgress<UploadProgress> progress, long? total)
        {
            _inner = inner;
            _ticker = new UploadProgressTicker(progress, total, UploadPhase.Sending);
        }

        public double? LastBytesPerSecond => _ticker.LastBytesPerSecond;

        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => _inner.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => _inner.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count)
        {
            _inner.Write(buffer, offset, count);
            _ticker.Add(count);
        }

        public override async Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            await _inner.WriteAsync(buffer, offset, count, cancellationToken).ConfigureAwait(false);
            _ticker.Add(count);
        }
    }

    // Advertise a known Length so StreamContent sets Content-Length on the multipart request
    public sealed class LengthOnlyStream : Stream
    {
        private readonly Stream _inner;
        private readonly long _length;
        private long _position;

        public LengthOnlyStream(Stream inner, long length)
        {
            _inner = inner;
            _length = length;
        }

        public override bool CanRead => _inner.CanRead;
        public override bool CanSeek => true;
        public override bool CanWrite => false;
        public override long Length => _length;
        public override long Position
        {
            get => _position;
            set => throw new NotSupportedException();
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count)
        {
            int n = _inner.Read(buffer, offset, count);
            _position += n;
            return n;
        }

        public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            int n = await _inner.ReadAsync(buffer, offset, count, cancellationToken).ConfigureAwait(false);
            _position += n;
            return n;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) _inner.Dispose();
            base.Dispose(disposing);
        }
    }
}
