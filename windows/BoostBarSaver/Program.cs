using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace BoostBar
{
    /// Windows screen saver entry point. Windows calls a .scr with:
    ///   /s          run full screen          /p <hwnd>   draw a little preview inside the Screen Saver Settings dialog
    ///   /c[:hwnd]   settings (opens BoostBar ▸ Settings ▸ Screen Saver)       (none) same as /c
    /// BoostBar's own "Preview" button uses /w: a normal resizable window.
    static class SaverProgram
    {
        public static string Scene;
        public static string Dir => Path.GetDirectoryName(Application.ExecutablePath);

        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Scene = SaverConfig.SceneFromExe(Application.ExecutablePath);
            var a = args.Select(x => x.Trim()).ToArray();
            var mode = a.Length > 0 ? a[0].ToLowerInvariant() : "/c";
            string Param() { var i = mode.IndexOf(':'); if (i > 0) return mode.Substring(i + 1); return a.Length > 1 ? a[1] : null; }
            if (mode.StartsWith("/s")) RunFullScreen();
            else if (mode.StartsWith("/w")) { var f = new SaverForm(windowed: true, Screen.PrimaryScreen); Application.Run(f); }
            else if (mode.StartsWith("/p")) { if (long.TryParse(Param(), out var h)) Application.Run(new PreviewForm(new IntPtr(h))); }
            else OpenSettings();
        }

        static void RunFullScreen()
        {
            var forms = Screen.AllScreens.Select(s => new SaverForm(windowed: false, s)).ToList();
            foreach (var f in forms.Skip(1)) f.Show();
            var watch = new InputWatch();
            watch.Start();
            Application.Run(forms[0]);
        }

        static void OpenSettings()
        {
            var app = Path.Combine(Dir, "BoostBar.exe");
            if (File.Exists(app)) Process.Start(app, "--settings \"Screen Saver\"");
            else MessageBox.Show("Set this screen saver up in BoostBar ▸ Settings ▸ Screen Saver.", SaverConfig.Title(Scene));
        }
    }

    /// Ends the screen saver on any key, click or real mouse move (after a short grace period).
    class InputWatch
    {
        readonly Timer t = new Timer { Interval = 100 };
        readonly Stopwatch clock = Stopwatch.StartNew();
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO l);
        POINT start; uint startInput; bool armed;

        public void Start()
        {
            t.Tick += (s, e) =>
            {
                var li = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
                GetLastInputInfo(ref li);
                GetCursorPos(out var p);
                if (!armed)
                {
                    if (clock.Elapsed.TotalSeconds < 1.2) return;
                    armed = true; start = p; startInput = li.dwTime; return;
                }
                var moved = Math.Abs(p.X - start.X) + Math.Abs(p.Y - start.Y) > 12;
                if (moved || li.dwTime != startInput) Application.Exit();
            };
            t.Start();
        }
    }

    /// One screen's worth of scene: WebView2 showing the saver page.
    class SaverForm : Form
    {
        readonly bool windowed;
        readonly WebView2 web = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Black };
        static Task<CoreWebView2Environment> env;

        public SaverForm(bool windowed, Screen screen)
        {
            this.windowed = windowed;
            BackColor = Color.Black;
            Text = SaverConfig.Title(SaverProgram.Scene) + (windowed ? " — Preview" : "");
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            if (windowed)
            {
                StartPosition = FormStartPosition.CenterScreen;
                Size = new Size(1000, 640);
            }
            else
            {
                FormBorderStyle = FormBorderStyle.None;
                StartPosition = FormStartPosition.Manual;
                Bounds = screen.Bounds;
                TopMost = true;
                ShowInTaskbar = false;
                Cursor.Hide();
            }
            Controls.Add(web);
            Load += async (s, e) => await Start();
        }

        async Task Start()
        {
            var page = Path.Combine(SaverProgram.Dir, "savers", SaverProgram.Scene + ".html");
            if (!File.Exists(page)) { Message("The scene file is missing — reinstall BoostBar."); return; }
            try
            {
                if (env == null)
                {
                    var data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BoostBar", "WebView2");
                    env = CoreWebView2Environment.CreateAsync(null, data, new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required"));
                }
                await web.EnsureCoreWebView2Async(await env);
                var core = web.CoreWebView2;
                core.Settings.AreDevToolsEnabled = false;
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.IsStatusBarEnabled = false;
                core.Settings.IsZoomControlEnabled = false;
                await core.AddScriptToExecuteOnDocumentCreatedAsync(SaverConfig.Script(SaverProgram.Scene));
                core.SetVirtualHostNameToFolderMapping("boostbar.saver", Path.GetDirectoryName(page), CoreWebView2HostResourceAccessKind.Allow);
                core.Navigate("https://boostbar.saver/" + SaverProgram.Scene + ".html");
            }
            catch (WebView2RuntimeNotFoundException)
            {
                Message("This screen saver needs the Microsoft Edge WebView2 Runtime (built into Windows 11).\nGet it from go.microsoft.com/fwlink/p/?LinkId=2124703");
            }
            catch (Exception e) { Message("Couldn't start the screen saver: " + e.Message); }
        }

        void Message(string text)
        {
            web.Visible = false;
            var l = new Label { Text = text, ForeColor = Color.FromArgb(86, 190, 55), BackColor = Color.Black, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 14f) };
            Controls.Add(l);
            l.BringToFront();
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            if (!windowed) Application.Exit();
            base.OnFormClosed(e);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (!windowed || keyData == Keys.Escape) { Close(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }
    }

    /// The thumbnail inside Windows' Screen Saver Settings dialog.
    class PreviewForm : Form
    {
        [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr c, IntPtr p);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
        readonly IntPtr parent;
        readonly Image thumb;
        readonly Timer alive = new Timer { Interval = 500 };

        public PreviewForm(IntPtr parent)
        {
            this.parent = parent;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            BackColor = Color.Black;
            DoubleBuffered = true;
            using (var st = typeof(PreviewForm).Assembly.GetManifestResourceStream("thumb_" + SaverProgram.Scene + ".png"))
                if (st != null) thumb = Image.FromStream(st);
            alive.Tick += (s, e) => { if (!IsWindow(this.parent)) Application.Exit(); };
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            SetParent(Handle, parent);
            SetWindowLong(Handle, -16, GetWindowLong(Handle, -16) | 0x40000000);   // WS_CHILD
            GetClientRect(parent, out var r);
            Location = Point.Empty;
            Size = new Size(r.R - r.L, r.B - r.T);
            alive.Start();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Color.Black);
            if (thumb == null) return;
            e.Graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            var s = Math.Min(Width / (float)thumb.Width, Height / (float)thumb.Height);
            var w = thumb.Width * s; var h = thumb.Height * s;
            e.Graphics.DrawImage(thumb, (Width - w) / 2, (Height - h) / 2, w, h);
        }
    }
}
