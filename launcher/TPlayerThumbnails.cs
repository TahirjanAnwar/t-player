// TPlayerThumbnails.dll: shows a frame of each video as its thumbnail in File Explorer.
// Windows can't make thumbnails of HEVC videos without Microsoft's paid codec, so this asks FFmpeg for a frame.
// Windows runs it in its separate thumbnail process (not inside Explorer) and hands it the video as a stream.
// setup.cmd builds it with Windows' own C# compiler; "tplayer.py --register" switches it on (current user only).
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

[assembly: AssemblyTitle("T-Player thumbnails")]
[assembly: AssemblyDescription("Video thumbnails for File Explorer, made with FFmpeg")]
[assembly: AssemblyProduct("T-Player")]
[assembly: AssemblyCompany("T-production")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: ComVisible(false)]

namespace TPlayer
{
    [ComImport, Guid("e357fccd-a995-4576-b01f-234630154e96"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IThumbnailProvider
    {
        void GetThumbnail(uint cx, out IntPtr hbitmap, out uint alphaType);
    }

    [ComImport, Guid("b824b49d-22ac-4161-ac8a-9916e8fa3f7f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IInitializeWithStream
    {
        void Initialize(IStream stream, uint mode);
    }

    [ComVisible(true), Guid("5F2722BF-DA9D-4983-AF1D-B5C441DBF04E"), ClassInterface(ClassInterfaceType.None)]
    public sealed class ThumbnailProvider : IThumbnailProvider, IInitializeWithStream
    {
        // Without a usable file path, the start and the end of the video are copied into a sparse temporary
        // file: enough for FFmpeg to read the index (often at the end) and the first seconds of picture.
        const long HeadBytes = 64L << 20, TailBytes = 16L << 20;
        const int WTSAT_RGB = 1;
        const int E_FAIL = unchecked((int)0x80004005);

        IStream stream;

        public void Initialize(IStream stream, uint mode)
        {
            this.stream = stream;
        }

        public void GetThumbnail(uint cx, out IntPtr hbitmap, out uint alphaType)
        {
            hbitmap = IntPtr.Zero;
            alphaType = WTSAT_RGB;
            string temp = null;
            try
            {
                string source = SourceFile(out temp);
                byte[] picture = Frame(source, (int)Math.Max(32, Math.Min(cx, 2560)));
                using (var memory = new MemoryStream(picture))
                using (var image = new Bitmap(memory))
                    hbitmap = image.GetHbitmap();
            }
            finally
            {
                if (stream != null)
                {
                    Marshal.ReleaseComObject(stream);   // let go of the video right away
                    stream = null;
                }
                if (temp != null)
                {
                    try { File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                }
            }
        }

        // The video's own path when Windows tells it, otherwise a temporary copy of its start and end.
        string SourceFile(out string temp)
        {
            temp = null;
            if (stream == null)
                throw new COMException("Not initialised", E_FAIL);
            System.Runtime.InteropServices.ComTypes.STATSTG stat;
            stream.Stat(out stat, 0);
            string name = stat.pwcsName ?? "";
            if (Environment.GetEnvironmentVariable("TPLAYER_THUMBS_STREAM_ONLY") == null
                && name.Length > 3 && Path.IsPathRooted(name) && File.Exists(name))
                return name;
            string ext = "";
            try { ext = Path.GetExtension(name); } catch (ArgumentException) { }
            temp = Path.Combine(Path.GetTempPath(), "T-Player thumbnail " + Guid.NewGuid().ToString("N") + ext);
            CopyStartAndEnd(stat.cbSize, temp);
            return temp;
        }

        void CopyStartAndEnd(long size, string target)
        {
            using (var file = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            {
                bool sparse = MakeSparse(file.SafeFileHandle);
                long head = Math.Min(size, HeadBytes);
                CopyRange(file, 0, head);
                if (size > head && sparse)
                {
                    long start = Math.Max(head, size - TailBytes);
                    file.SetLength(size);            // the gap in between takes no disk space
                    CopyRange(file, start, size - start);
                }
            }
        }

        void CopyRange(FileStream file, long offset, long count)
        {
            var buffer = new byte[1 << 20];
            IntPtr read = Marshal.AllocCoTaskMem(4);
            try
            {
                stream.Seek(offset, 0, IntPtr.Zero);
                file.Position = offset;
                while (count > 0)
                {
                    stream.Read(buffer, (int)Math.Min(buffer.Length, count), read);
                    int got = Marshal.ReadInt32(read);
                    if (got <= 0)
                        break;
                    file.Write(buffer, 0, got);
                    count -= got;
                }
            }
            finally
            {
                Marshal.FreeCoTaskMem(read);
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle device, uint code, IntPtr inBuffer, uint inSize,
                                           IntPtr outBuffer, uint outSize, out uint returned, IntPtr overlapped);

        static bool MakeSparse(SafeFileHandle file)
        {
            uint returned;
            return DeviceIoControl(file, 0x000900C4 /* FSCTL_SET_SPARSE */, IntPtr.Zero, 0, IntPtr.Zero, 0,
                                   out returned, IntPtr.Zero);
        }

        // One frame as a BMP: the key frame at about 1 second (the very first frame for shorter clips).
        static byte[] Frame(string source, int size)
        {
            foreach (string seconds in new[] { "1", "0" })
            {
                byte[] picture = RunFfmpeg(seconds, source, size);
                if (picture != null && picture.Length > 54)
                    return picture;
            }
            throw new COMException("FFmpeg gave no picture", E_FAIL);
        }

        static byte[] RunFfmpeg(string seconds, string source, int size)
        {
            string args = "-hide_banner -loglevel error -nostdin -threads 2 -noaccurate_seek -skip_frame nokey"
                        + " -ss " + seconds + " -i \"" + source + "\" -map 0:v:0 -frames:v 1 -an -sn -dn"
                        + " -vf \"scale=" + size + ":" + size + ":force_original_aspect_ratio=decrease\""
                        + " -f image2pipe -c:v bmp pipe:1";
            var start = new ProcessStartInfo(FfmpegPath(), args);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            using (Process ffmpeg = Process.Start(start))
            {
                try { ffmpeg.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (InvalidOperationException) { }
                var picture = new MemoryStream();
                var copy = ffmpeg.StandardOutput.BaseStream.CopyToAsync(picture);
                if (!ffmpeg.WaitForExit(20000))
                {
                    try { ffmpeg.Kill(); } catch (InvalidOperationException) { }
                    return null;
                }
                copy.Wait(5000);
                return ffmpeg.ExitCode == 0 ? picture.ToArray() : null;
            }
        }

        // The ffmpeg.exe that "tplayer.py --register" found, then one next to this DLL, then the PATH.
        static string FfmpegPath()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\T-Player"))
                {
                    string saved = key == null ? null : key.GetValue("FFmpeg") as string;
                    if (!string.IsNullOrEmpty(saved) && File.Exists(saved))
                        return saved;
                }
            }
            catch (System.Security.SecurityException) { }
            string here = Path.Combine(Path.GetDirectoryName(typeof(ThumbnailProvider).Assembly.Location), "ffmpeg.exe");
            return File.Exists(here) ? here : "ffmpeg.exe";
        }
    }
}
