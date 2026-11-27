// T-Player.exe: starts T-Player with its own Python (.venv) and passes on the video to open.
// setup.cmd builds it with the C# compiler that comes with Windows (.NET Framework 4), so there is
// a real program with a name and an icon to choose under "Open with" and to pin to the taskbar.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("T-Player")]
[assembly: AssemblyDescription("T-Player video player")]
[assembly: AssemblyProduct("T-Player")]
[assembly: AssemblyCompany("T-production")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string python = Path.Combine(dir, @".venv\Scripts\pythonw.exe");
        string script = Path.Combine(dir, "tplayer.py");
        if (!File.Exists(python) || !File.Exists(script))
        {
            MessageBox.Show("T-Player isn't set up yet.\n\nRun setup.cmd in:\n" + dir, "T-Player",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 1;
        }
        StringBuilder line = new StringBuilder(Quote(script));
        foreach (string arg in args)
            line.Append(' ').Append(Quote(arg));
        ProcessStartInfo start = new ProcessStartInfo(python, line.ToString());
        start.UseShellExecute = false;
        start.WorkingDirectory = dir;
        try
        {
            Process.Start(start);
        }
        catch (Exception error)
        {
            MessageBox.Show("T-Player couldn't start:\n" + error.Message, "T-Player",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    // Quotes one argument the way Windows programs split their command line.
    static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
            return arg;
        StringBuilder text = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\') { slashes++; continue; }
            text.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
            text.Append(c);
            slashes = 0;
        }
        text.Append('\\', slashes * 2);
        return text.Append('"').ToString();
    }
}
