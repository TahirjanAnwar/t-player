// Development check for TPlayerThumbnails.dll. Saves each video's thumbnail as a PNG and prints the time taken.
//   thumbtest direct OUT_DIR SIZE video...   calls the add-on directly with a stream, the way Windows does
//   thumbtest shell  OUT_DIR SIZE video...   asks Windows for the thumbnail (needs "tplayer.py --register")
// Build: csc /reference:TPlayerThumbnails.dll /reference:System.Drawing.dll /out:thumbtest.exe tools\thumbtest.cs
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using TPlayer;

static class ThumbTest
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateStreamOnFileEx(string file, uint mode, uint attributes, bool create,
                                              IntPtr template, out IStream stream);

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        void GetImage(Size size, int flags, out IntPtr hbitmap);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr bindContext, [In] ref Guid iid,
                                                   [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr handle);

    static int Main(string[] args)
    {
        string mode = args[0], outDir = args[1];
        int size = int.Parse(args[2]);
        Directory.CreateDirectory(outDir);
        int failures = 0;
        for (int i = 3; i < args.Length; i++)
        {
            string video = args[i];
            var clock = Stopwatch.StartNew();
            try
            {
                IntPtr bitmap;
                if (mode == "shell")
                {
                    Guid iid = typeof(IShellItemImageFactory).GUID;
                    IShellItemImageFactory item;
                    SHCreateItemFromParsingName(video, IntPtr.Zero, ref iid, out item);
                    item.GetImage(new Size(size, size), 0x8 /* SIIGBF_THUMBNAILONLY */, out bitmap);
                }
                else
                {
                    IStream stream;
                    SHCreateStreamOnFileEx(video, 0x40 /* STGM_READ | STGM_SHARE_DENY_NONE */, 0, false, IntPtr.Zero, out stream);
                    var provider = new ThumbnailProvider();
                    ((IInitializeWithStream)provider).Initialize(stream, 0);
                    uint alpha;
                    ((IThumbnailProvider)provider).GetThumbnail((uint)size, out bitmap, out alpha);
                }
                using (Image image = Image.FromHbitmap(bitmap))
                {
                    string png = Path.Combine(outDir, Path.GetFileNameWithoutExtension(video) + ".png");
                    image.Save(png, ImageFormat.Png);
                    Console.WriteLine("{0,-34} {1,5} ms  {2}x{3}", Path.GetFileName(video), clock.ElapsedMilliseconds,
                                      image.Width, image.Height);
                }
                DeleteObject(bitmap);
            }
            catch (Exception error)
            {
                failures++;
                Console.WriteLine("{0,-34} FAILED after {1} ms: {2}", Path.GetFileName(video), clock.ElapsedMilliseconds,
                                  error.Message);
            }
        }
        return failures;
    }
}
