// Micro Wi-Fi Guard - per-user installer (no admin needed). Built with the C# compiler that ships with Windows.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program
{
    public const string AppName = "Micro Wi-Fi Guard";
    public const string UninstKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\MicroWiFiGuard";

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MicroWiFiGuard");
        bool uninstall = false, quiet = false, silent = false;
        foreach (string a in args)
        {
            string l = a.ToLowerInvariant();
            if (l == "/uninstall" || l == "-uninstall") uninstall = true;
            if (l == "/quiet" || l == "-quiet") quiet = true;
            if (l == "/silent" || l == "-silent") silent = true;                    // unattended install (IT / scripts)
            if (l.StartsWith("/dir=")) dir = a.Substring(5).Trim('"');
        }
        if (uninstall) return Setup.Uninstall(dir, quiet);
        if (silent) { string e = Setup.Install(dir, false, true, false); return e == null ? 0 : 1; }
        Application.Run(new SetupForm(dir));
        return 0;
    }
}

static class Setup
{
    public static bool IsRunning()
    {
        Mutex m;
        if (Mutex.TryOpenExisting(@"Local\MicroWiFiGuard", out m)) { m.Dispose(); return true; }
        return false;
    }

    static string PsExe() { return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"); }
    static string StartMenuDir() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), Program.AppName); }
    static string StartupLink() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Micro Wi-Fi Guard.lnk"); }
    static string DesktopLink() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Program.AppName + ".lnk"); }

    static void MakeShortcut(string lnk, string target, string args, string workDir, string icon, string desc)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        object sh = Activator.CreateInstance(t);
        object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
        Type st = sc.GetType();
        st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { target });
        st.InvokeMember("Arguments", BindingFlags.SetProperty, null, sc, new object[] { args });
        st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { workDir });
        st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { desc });
        if (File.Exists(icon)) st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { icon });
        st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
    }

    public static string Install(string dir, bool desktop, bool startWithWindows, bool launch)
    {
        if (IsRunning()) return "Micro is running. Right-click its tray icon, choose Exit, then run setup again.";
        Directory.CreateDirectory(dir);
        string version = "1.0.0";
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream rs = asm.GetManifestResourceStream("payload.zip"))
        using (ZipArchive zip = new ZipArchive(rs, ZipArchiveMode.Read))
        {
            string root = Path.GetFullPath(dir) + Path.DirectorySeparatorChar;
            foreach (ZipArchiveEntry e in zip.Entries)
            {
                string rel = e.FullName.Replace('\\', '/');
                if (rel.EndsWith("/")) continue;
                if (rel.StartsWith("MonitorData/", StringComparison.OrdinalIgnoreCase)) continue;      // never ship or overwrite user data
                string dest = Path.GetFullPath(Path.Combine(dir, rel.Replace('/', Path.DirectorySeparatorChar)));
                if (!dest.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;              // zip-slip guard
                if (rel.StartsWith("assets/", StringComparison.OrdinalIgnoreCase) && File.Exists(dest)) continue;   // keep the user's own GIFs / voices
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                e.ExtractToFile(dest, true);
                if (rel == "version.txt") version = File.ReadAllText(dest).Trim();
            }
        }
        Directory.CreateDirectory(Path.Combine(dir, "MonitorData"));
        string settings = Path.Combine(dir, @"MonitorData\settings.json");
        if (!startWithWindows && !File.Exists(settings)) File.WriteAllText(settings, "{ \"StartWithWindows\": false, \"StartupNotified\": true }");
        string setupCopy = Path.Combine(dir, "setup.exe");
        if (!string.Equals(Path.GetFullPath(Application.ExecutablePath), Path.GetFullPath(setupCopy), StringComparison.OrdinalIgnoreCase))
            File.Copy(Application.ExecutablePath, setupCopy, true);

        string ps1 = Path.Combine(dir, "Micro-WiFi.ps1");
        string args = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"";
        string ico = Path.Combine(dir, "micro.ico");
        string sm = StartMenuDir(); Directory.CreateDirectory(sm);
        MakeShortcut(Path.Combine(sm, Program.AppName + ".lnk"), PsExe(), args, dir, ico, "Wi-Fi guard widget");
        MakeShortcut(Path.Combine(sm, "Full test and dashboard.lnk"), Path.Combine(dir, "Run-WiFi-Analyzer.bat"), "", dir, ico, "Run the Full Wi-Fi test");
        MakeShortcut(Path.Combine(sm, "Uninstall.lnk"), setupCopy, "/uninstall", dir, ico, "Remove " + Program.AppName);
        if (desktop) MakeShortcut(DesktopLink(), PsExe(), args, dir, ico, "Wi-Fi guard widget");

        using (RegistryKey k = Registry.CurrentUser.CreateSubKey(Program.UninstKey))
        {
            k.SetValue("DisplayName", Program.AppName);
            k.SetValue("DisplayVersion", version);
            k.SetValue("Publisher", "Micro");
            k.SetValue("InstallLocation", dir);
            k.SetValue("DisplayIcon", ico);
            k.SetValue("UninstallString", "\"" + setupCopy + "\" /uninstall");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
        if (launch)
        {
            ProcessStartInfo psi = new ProcessStartInfo(PsExe(), args);
            psi.WorkingDirectory = dir; psi.UseShellExecute = false; psi.CreateNoWindow = true;
            Process.Start(psi);
        }
        return null;
    }

    public static int Uninstall(string dir, bool quiet)
    {
        if (IsRunning())
        {
            if (!quiet) MessageBox.Show("Micro is running. Right-click its tray icon, choose Exit, then uninstall again.", Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 1;
        }
        bool deleteData = false;
        if (!quiet)
        {
            DialogResult r = MessageBox.Show("Remove " + Program.AppName + "?\n\nYes = remove everything including saved data (device names, history, settings).\nNo = remove the program but keep my data.\nCancel = do nothing.",
                Program.AppName, MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Cancel) return 1;
            deleteData = (r == DialogResult.Yes);
        }
        try { if (File.Exists(StartupLink())) File.Delete(StartupLink()); } catch { }
        try { if (File.Exists(DesktopLink())) File.Delete(DesktopLink()); } catch { }
        try { if (Directory.Exists(StartMenuDir())) Directory.Delete(StartMenuDir(), true); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(Program.UninstKey, false); } catch { }
        string self = Path.GetFullPath(Application.ExecutablePath);
        if (Directory.Exists(dir))
        {
            foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
            {
                string rel = f.Substring(dir.Length).TrimStart('\\');
                if (string.Equals(Path.GetFullPath(f), self, StringComparison.OrdinalIgnoreCase)) continue;
                if (!deleteData && (rel.StartsWith("MonitorData\\", StringComparison.OrdinalIgnoreCase) || rel.StartsWith("assets\\", StringComparison.OrdinalIgnoreCase))) continue;
                try { File.Delete(f); } catch { }
            }
            foreach (string d in Directory.GetDirectories(dir, "*", SearchOption.AllDirectories))
            {
                try { if (Directory.GetFileSystemEntries(d).Length == 0) Directory.Delete(d); } catch { }
            }
        }
        // setup.exe cannot delete itself while running: hand that to a tiny delayed command.
        string cmd = "/c ping 127.0.0.1 -n 3 >nul & del /f /q \"" + self + "\" & rmdir \"" + dir + "\"";
        ProcessStartInfo p = new ProcessStartInfo("cmd.exe", cmd);
        p.CreateNoWindow = true; p.UseShellExecute = false; p.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(p);
        if (!quiet) MessageBox.Show(Program.AppName + " was removed." + (deleteData ? "" : "\nYour data is still in: " + dir), Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }
}

class SetupForm : Form
{
    TextBox path; CheckBox cDesk, cStart, cLaunch; Button btn; Label status;

    public SetupForm(string dir)
    {
        Text = Program.AppName + " - Setup";
        ClientSize = new Size(500, 330); FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);
        Label h = new Label(); h.Text = "Micro Wi-Fi Guard"; h.Font = new Font("Segoe UI Semibold", 16f); h.SetBounds(20, 14, 460, 32); Controls.Add(h);
        Label d = new Label(); d.SetBounds(20, 52, 460, 56);
        d.Text = "A small always-on-top widget that watches your Wi-Fi: signal, speed, devices on your network, and a scam-filter (DNS) check.\r\nEverything stays on this PC. No administrator rights needed.";
        Controls.Add(d);
        Label l = new Label(); l.Text = "Install to:"; l.SetBounds(20, 118, 100, 20); Controls.Add(l);
        path = new TextBox(); path.Text = dir; path.SetBounds(20, 140, 370, 24); Controls.Add(path);
        Button br = new Button(); br.Text = "Browse..."; br.SetBounds(398, 138, 84, 28); Controls.Add(br);
        br.Click += delegate { using (FolderBrowserDialog f = new FolderBrowserDialog()) { if (f.ShowDialog() == DialogResult.OK) path.Text = Path.Combine(f.SelectedPath, "MicroWiFiGuard"); } };
        cDesk = new CheckBox(); cDesk.Text = "Create a desktop shortcut"; cDesk.Checked = true; cDesk.SetBounds(20, 178, 440, 22); Controls.Add(cDesk);
        cStart = new CheckBox(); cStart.Text = "Start with Windows (recommended)"; cStart.Checked = true; cStart.SetBounds(20, 204, 440, 22); Controls.Add(cStart);
        cLaunch = new CheckBox(); cLaunch.Text = "Start Micro when setup finishes"; cLaunch.Checked = true; cLaunch.SetBounds(20, 230, 440, 22); Controls.Add(cLaunch);
        status = new Label(); status.SetBounds(20, 262, 460, 20); status.ForeColor = Color.DarkRed; Controls.Add(status);
        btn = new Button(); btn.Text = "Install"; btn.SetBounds(310, 288, 84, 30); Controls.Add(btn);
        Button cancel = new Button(); cancel.Text = "Cancel"; cancel.SetBounds(400, 288, 84, 30); cancel.Click += delegate { Close(); }; Controls.Add(cancel);
        AcceptButton = btn; CancelButton = cancel;
        btn.Click += delegate { DoInstall(); };
    }

    void DoInstall()
    {
        btn.Enabled = false; status.ForeColor = Color.Black; status.Text = "Installing..."; Refresh();
        try
        {
            string err = Setup.Install(path.Text.Trim(), cDesk.Checked, cStart.Checked, cLaunch.Checked);
            if (err != null) { status.ForeColor = Color.DarkRed; status.Text = err; btn.Enabled = true; return; }
            MessageBox.Show("Micro Wi-Fi Guard is installed.\n\nLook for the Wi-Fi icon in the tray (bottom-right). Ctrl+Alt+W shows or hides the widget.\nThe admin PIN is created the first time you open Settings.", Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
            Close();
        }
        catch (Exception ex)
        {
            status.ForeColor = Color.DarkRed; status.Text = "Setup failed: " + ex.Message; btn.Enabled = true;
        }
    }
}
