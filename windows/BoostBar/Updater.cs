using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BoostBar
{
    /// Starts BoostBar when you sign in (HKCU Run key).
    static class LoginItem
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        public static bool IsEnabled
        {
            get { try { using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k?.GetValue("BoostBar") != null; } catch { return false; } }
        }
        public static void Set(bool on)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue("BoostBar", "\"" + Application.ExecutablePath + "\" --login");
                else k.DeleteValue("BoostBar", false);
            }
        }
    }

    /// Checks GitHub Releases for a newer BoostBar-Setup.exe and installs it in place (checksum verified).
    class Updater
    {
        public const string Repo = "macsboost/BoostBar";
        public static string ReleasesPage => "https://github.com/" + Repo + "/releases";
        public static string RepoPage => "https://github.com/" + Repo;
        const string SetupAsset = "BoostBar-Setup.exe";

        public static string CurrentVersion
        {
            get
            {
                var v = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
                if (string.IsNullOrEmpty(v)) v = Application.ProductVersion;
                var plus = v.IndexOf('+');
                return plus > 0 ? v.Substring(0, plus) : v;
            }
        }

        readonly SynchronizationContext ui = SynchronizationContext.Current;
        bool checking;

        static HttpClient Client()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var c = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            c.DefaultRequestHeaders.UserAgent.ParseAdd("BoostBar-Windows/" + CurrentVersion);
            return c;
        }

        public void Check(bool userInitiated)
        {
            if (checking) return;
            checking = true;
            Task.Run(async () =>
            {
                string error = null;
                Dictionary<string, object> rel = null;
                try
                {
                    using (var c = Client())
                    {
                        c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
                        var resp = await c.GetAsync("https://api.github.com/repos/" + Repo + "/releases/latest");
                        if (resp.StatusCode == HttpStatusCode.NotFound) error = "No releases published yet.";
                        else if (!resp.IsSuccessStatusCode) error = "GitHub returned HTTP " + (int)resp.StatusCode + ".";
                        else rel = Json.Parse(await resp.Content.ReadAsStringAsync());
                    }
                }
                catch (Exception e) { error = e.Message; }
                ui.Post(_ =>
                {
                    checking = false;
                    if (rel == null) { if (userInitiated) Alert("Couldn't check for updates", error ?? "Unexpected reply from GitHub."); return; }
                    Handle(rel, userInitiated);
                }, null);
            });
        }

        void Handle(Dictionary<string, object> rel, bool userInitiated)
        {
            var tag = rel.Str("tag_name") ?? "";
            var latest = tag.StartsWith("v") ? tag.Substring(1) : tag;
            if (!IsNewer(latest, CurrentVersion))
            {
                if (userInitiated) Alert("You're up to date", "BoostBar " + CurrentVersion + " is the latest version.");
                return;
            }
            string setupUrl = null, shaUrl = null;
            if (rel.TryGetValue("assets", out var a) && a is IEnumerable list)
                foreach (var o in list)
                    if (o is Dictionary<string, object> asset)
                    {
                        var name = asset.Str("name");
                        if (name == SetupAsset) setupUrl = asset.Str("browser_download_url");
                        if (name == SetupAsset + ".sha256") shaUrl = asset.Str("browser_download_url");
                    }
            if (setupUrl == null || shaUrl == null)
            {
                // The Mac build can finish first: the Windows installer joins the release a few minutes later.
                if (userInitiated && MessageBox.Show("BoostBar " + latest + " is out, but its Windows installer isn't posted yet. Open the releases page?",
                        "BoostBar", MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
                    Shell.Open(rel.Str("html_url") ?? ReleasesPage);
                return;
            }
            if (!userInitiated && Prefs.AutoUpdate) { Install(setupUrl, shaUrl, latest, quiet: true); return; }

            var notes = (rel.Str("body") ?? "").Trim();
            if (notes.Length > 600) notes = notes.Substring(0, 600) + "…";
            using (var f = new UpdatePrompt(latest, notes))
            {
                var r = f.ShowDialog();
                if (f.AutoFromNowOn) Prefs.AutoUpdate = true;
                if (r == DialogResult.Yes) Install(setupUrl, shaUrl, latest, quiet: false);
                else if (r == DialogResult.Retry) Shell.Open(rel.Str("html_url") ?? ReleasesPage);
            }
        }

        void Install(string setupUrl, string shaUrl, string version, bool quiet)
        {
            Task.Run(async () =>
            {
                string error = null, path = null;
                try
                {
                    using (var c = Client())
                    {
                        c.Timeout = TimeSpan.FromMinutes(10);
                        var expected = (await c.GetStringAsync(shaUrl)).Trim().Split(' ', '\t', '\r', '\n')[0].ToLowerInvariant();
                        var bytes = await c.GetByteArrayAsync(setupUrl);
                        string actual;
                        using (var sha = SHA256.Create()) actual = string.Concat(sha.ComputeHash(bytes).Select(b => b.ToString("x2")));
                        if (expected.Length != 64 || actual != expected) error = "The download didn't match its published checksum, so it wasn't installed.";
                        else
                        {
                            path = Path.Combine(Path.GetTempPath(), "BoostBar-Setup-" + version + ".exe");
                            File.WriteAllBytes(path, bytes);
                        }
                    }
                }
                catch (Exception e) { error = e.Message; }
                ui.Post(_ =>
                {
                    if (error != null) { if (!quiet) Alert("Update failed", error); return; }   // quiet: try again next launch
                    try
                    {
                        Process.Start(new ProcessStartInfo(path, quiet ? "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS" : "/SILENT /NORESTART /CLOSEAPPLICATIONS")
                        { UseShellExecute = true });
                        Application.Exit();
                    }
                    catch (Exception e) { if (!quiet) Alert("Update failed", e.Message); }
                }, null);
            });
        }

        public static bool IsNewer(string a, string b)
        {
            int[] P(string s) => s.Split('.').Select(x => int.TryParse(new string(x.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0).ToArray();
            var x1 = P(a); var y1 = P(b);
            for (var i = 0; i < Math.Max(x1.Length, y1.Length); i++)
            {
                var p = i < x1.Length ? x1[i] : 0; var q = i < y1.Length ? y1[i] : 0;
                if (p != q) return p > q;
            }
            return false;
        }

        public static void Alert(string title, string text) => MessageBox.Show(text, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    /// "BoostBar x.y.z is available" with Install / Release Notes / Later and an auto-update checkbox.
    class UpdatePrompt : Form
    {
        readonly CheckBox auto = new CheckBox { Text = "Install future updates automatically", AutoSize = true };
        public bool AutoFromNowOn => auto.Checked;

        public UpdatePrompt(string version, string notes)
        {
            Text = "BoostBar Update";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new System.Drawing.Font("Segoe UI", 9.5f);
            TopMost = true;
            ClientSize = new System.Drawing.Size(460, 300);
            var title = new Label { Text = "BoostBar " + version + " is available", Font = new System.Drawing.Font("Segoe UI Semibold", 12f), AutoSize = true, Left = 16, Top = 14 };
            var sub = new Label { Text = "You have " + Updater.CurrentVersion + ".", AutoSize = true, Left = 16, Top = 44 };
            var box = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Left = 16, Top = 70, Width = 428, Height = 140, Text = notes.Replace("\n", "\r\n") };
            auto.Left = 16; auto.Top = 220;
            var install = new Button { Text = "Install && Relaunch", DialogResult = DialogResult.Yes, Left = 254, Top = 254, Width = 190, Height = 32 };
            var page = new Button { Text = "Release Notes", DialogResult = DialogResult.Retry, Left = 130, Top = 254, Width = 116, Height = 32 };
            var later = new Button { Text = "Later", DialogResult = DialogResult.Cancel, Left = 16, Top = 254, Width = 100, Height = 32 };
            Controls.AddRange(new Control[] { title, sub, box, auto, install, page, later });
            AcceptButton = install; CancelButton = later;
        }
    }

    /// Anonymous install counter: one small JSON POST to biz-cord.com per version per PC (random ID, version,
    /// Windows version, CPU type). Retries on later launches until the server answers 2xx. Can be turned off.
    static class InstallPing
    {
        const string Endpoint = "https://biz-cord.com/api/public/boostbar/install";

        public static void SendIfNeeded()
        {
            if (!Prefs.ShareInstallCount) return;
            var version = Updater.CurrentVersion;
            var previous = Prefs.GetString("installPingVersion", null);
            if (previous == version) return;
            var id = Prefs.GetString("installID", null);
            if (string.IsNullOrEmpty(id)) { id = Guid.NewGuid().ToString().ToUpperInvariant(); Prefs.SetString("installID", id); }
            var os = Environment.OSVersion.Version;
            var arch = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432") ?? Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") ?? "";
            arch = arch.ToUpperInvariant() == "ARM64" ? "arm64" : arch.ToUpperInvariant() == "X86" ? "x86" : "x86_64";
            var body = Json.Write(new Dictionary<string, object>
            {
                ["app"] = "BoostBar", ["event"] = previous == null ? "install" : "update", ["install_id"] = id,
                ["version"] = version, ["previous_version"] = previous, ["platform"] = "windows", ["macos"] = null,
                ["windows"] = $"{os.Major}.{os.Minor}.{os.Build}", ["arch"] = arch, ["channel"] = "windows",
            });
            Task.Run(async () =>
            {
                try
                {
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                    using (var c = new HttpClient { Timeout = TimeSpan.FromSeconds(15) })
                    {
                        c.DefaultRequestHeaders.UserAgent.ParseAdd("BoostBar-Windows/" + version);
                        var r = await c.PostAsync(Endpoint, new StringContent(body, System.Text.Encoding.UTF8, "application/json"));
                        if (r.IsSuccessStatusCode) Prefs.SetString("installPingVersion", version);
                    }
                }
                catch { }
            });
        }
    }
}
